import CoreImage
import Darwin
import Foundation
import ImageIO

/// 雅迪仪表投屏输出模块。
///
/// 与九号/台铃/极核不同，雅迪走的是「TCP 8888 控制通道 + UDP 8889 图片通道」，
/// 画面为 JPEG 图片（按 1434 字节分片），而非 H.264 视频流。协议细节见 `YadeaProtocol`。
///
/// 流程（对应 YuRong 的 MirrorEngine + FrameSender）：
/// 1. 连接仪表 TCP 8888，发送 HEARTBEAT + NAV_START；
/// 2. 等待 0x20 响应，解析仪表显示配置（分辨率/帧率，默认 800×480@10）；
/// 3. 每秒发送心跳，同时按帧率取 CarPlay 画面 → JPEG 编码 → 分片走 UDP 8889；
/// 4. 结束发送 NAV_END。
final class YadeaOutput {
    private let queue = DispatchQueue(label: "CarWithin.yadea", qos: .userInitiated)
    private var session: Session?

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, onState: @escaping (String) -> Void,
               onLog: @escaping (String) -> Void, requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        queue.async { next.start(localAddress, targetAddress) }
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    private final class Session: @unchecked Sendable {
        let queue: DispatchQueue
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?

        private var timer: DispatchSourceTimer?
        private var tcp: YadeaTCPSocket?
        private var udp: NinebotUDPSocket?
        private var rxBuffer: [UInt8] = []

        private var decoder: TailingH264Decoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var fresh = false
        private var lastFrame = -Double.infinity
        private var lastCodecFailure = -Double.infinity

        private var navConfig = NavDisplayConfig()
        private var imageSequence = 1
        private var nextHeartbeat = 0.0
        private var nextFrameAt = 0.0
        private var status = ""

        private enum Phase { case connecting, negotiating, running }
        private var phase = Phase.connecting
        private var negotiatedAt = 0.0

        init(queue: DispatchQueue, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
        }

        func start(_ local: String, _ target: String) {
            guard active else { return }
            report("正在连接雅迪仪表…")
            do {
                udp = try NinebotUDPSocket(localIP: local, localPort: 0, remoteIP: target, remotePort: YadeaProtocol.imagePort)
                let control = YadeaTCPSocket()
                try control.connect(remoteIP: target, port: YadeaProtocol.controlPort)
                tcp = control
                onLog("雅迪：TCP 8888 控制 + UDP 8889 图片 · JPEG 分片")
                // 启动序列：HEARTBEAT + NAV_START 合并一条 TCP 发送
                let startup = YadeaProtocol.buildFullFrame(type: YadeaProtocol.cmdHeartbeat,
                                                           payload: YadeaProtocol.buildHeartbeatPayload())
                    + YadeaProtocol.buildFullFrame(type: YadeaProtocol.cmdNavStart,
                                                   payload: YadeaProtocol.buildNavStartPayload())
                try control.write(YadeaProtocol.data(startup))
                phase = .negotiating
                negotiatedAt = ProcessInfo.processInfo.systemUptime
                report("已发送握手命令，等待仪表回应…")

                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            } catch { fail(error) }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() { lock.withLock { cancelled = true } }

        func append(_ data: Data, keyframe: Bool) {
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image { latest = image; fresh = true }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        // MARK: - 主循环

        private func tick() {
            guard active else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch phase {
            case .connecting:
                break // start() 同步完成 TCP 连接后才进入 negotiating
            case .negotiating:
                drainResponses()
                if now - negotiatedAt > 4 {
                    // 未收到 0x20，按默认 800×480@10 继续（YuRong 同款兜底）
                    onLog("未收到 0x20 配置，使用默认 \(navConfig.summary)")
                    beginRunning(now: now)
                }
            case .running:
                runFrameAndHeartbeat(now: now)
            }
        }

        private func drainResponses() {
            guard let tcp else { return }
            do {
                while let chunk = try tcp.readSome(maxBytes: 4096, timeoutMs: 0) {
                    rxBuffer.append(contentsOf: YadeaProtocol.bytes(chunk))
                }
                while let frame = nextBufferedFrame() {
                    let cmd = frame.type
                    if cmd == YadeaProtocol.cmdNavStartResponse {
                        navConfig = YadeaProtocol.parseNavDisplayConfig(frame.payload)
                        onLog("协商成功：\(navConfig.summary)，capability=0x\(String(format: "%02X", navConfig.capabilities))")
                        report("仪表已回应，正在投屏 · \(navConfig.summary)")
                        beginRunning(now: ProcessInfo.processInfo.systemUptime)
                    } else {
                        onLog("收到命令 0x\(String(format: "%02X", Int(cmd)))（等待 0x20）")
                    }
                }
            } catch {
                onLog("读取仪表响应失败：\(error.localizedDescription)")
            }
        }

        /// 从缓冲中扫描魔数 5944 解析出一帧，解析到即返回并移除。
        private func nextBufferedFrame() -> (type: UInt8, payload: [UInt8])? {
            while rxBuffer.count >= 12 {
                // 扫描魔数 59 44
                var pos = -1
                for i in 0...(rxBuffer.count - 2) where rxBuffer[i] == 0x59 && rxBuffer[i + 1] == 0x44 {
                    pos = i
                    break
                }
                guard pos >= 0 else { rxBuffer.removeAll(); return nil }
                if pos > 0 { rxBuffer.removeFirst(pos) }
                guard rxBuffer.count >= 7 else { return nil }
                let innerLen = Int(YadeaProtocol.readUInt32BE(rxBuffer, offset: 3))
                guard innerLen >= 3, innerLen <= 1_048_576 else { rxBuffer.removeFirst(); continue }
                let totalFrameLen = innerLen + 7
                guard rxBuffer.count >= totalFrameLen else { return nil }
                guard rxBuffer[totalFrameLen - 2] == 0x4B, rxBuffer[totalFrameLen - 1] == 0x4A else {
                    rxBuffer.removeFirst(); continue
                }
                let frame = Array(rxBuffer[0..<totalFrameLen])
                rxBuffer.removeFirst(totalFrameLen)
                if let parsed = YadeaProtocol.parseFrame(frame) {
                    return (parsed.type, parsed.payload)
                }
            }
            return nil
        }

        private func beginRunning(now: Double) {
            phase = .running
            nextFrameAt = now
            nextHeartbeat = now
            report("正在投屏 · \(navConfig.summary) · JPEG")
        }

        private func runFrameAndHeartbeat(now: Double) {
            guard let tcp else { return }
            // 心跳：每秒一次
            if now >= nextHeartbeat {
                nextHeartbeat = now + 1
                do {
                    try tcp.write(YadeaProtocol.data(YadeaProtocol.buildFullFrame(
                        type: YadeaProtocol.cmdHeartbeat, payload: YadeaProtocol.buildHeartbeatPayload())))
                } catch let error as YadeaError where error.isTransient {}
                catch { fail(error) }
            }
            // 帧：按协商帧率
            guard now >= nextFrameAt else { return }
            nextFrameAt += Double(navConfig.frameIntervalMs) / 1000.0
            if nextFrameAt < now { nextFrameAt = now + Double(navConfig.frameIntervalMs) / 1000.0 }
            guard let latest, fresh || now - lastFrame >= 0.5 else { return }
            lastFrame = now
            fresh = false
            guard let jpeg = encodeJPEG(latest, width: navConfig.width, height: navConfig.height) else { return }
            let timestamp = UInt32(Int64(Date().timeIntervalSince1970 * 1000) & 0xFFFFFFFF)
            let frames = YadeaProtocol.buildImageFrames(image: YadeaProtocol.bytes(jpeg), imageSeq: imageSequence,
                                                        timestamp: timestamp)
            do {
                guard let udp else { return }
                for (index, frame) in frames.enumerated() {
                    guard active else { return }
                    try udp.send(YadeaProtocol.data(frame))
                    // 分片较多时轻微退避，避免 Wi-Fi 驱动队列溢出丢包
                    if frames.count > 20, index + 1 < frames.count, (index + 1).isMultiple(of: 8) {
                        usleep(500)
                    }
                }
                imageSequence &+= 1
            } catch let error as NinebotSocketError where error.isTransient {}
            catch { fail(error) }
        }

        // MARK: - JPEG 编码

        private func encodeJPEG(_ image: CVPixelBuffer, width: Int, height: Int) -> Data? {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            func jpeg(_ source: CIImage, _ quality: Int) -> Data? {
                compositor.jpegRepresentation(of: source, colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: CGFloat(quality) / 100])
            }
            let fitted = fittedImage(CIImage(cvPixelBuffer: image), width: width, height: height)
            // Auto 画质：大图用 72，超硬上限 80KB 时降质重试一次（YuRong 同款策略）
            if let first = jpeg(fitted, 72), first.count <= YadeaProtocol.imageHardLimit { return first }
            if let retried = jpeg(fitted, 64) { return retried }
            return nil
        }

        /// 铺满目标区域后居中裁切，避免黑边。
        ///
        /// 仪表屏是 800×384（≈2.08:1），而 CarPlay 请求的是 800×480（16:9），
        /// 等比「适配」会在左右各留 80px 黑边（合计占宽 20%），观感很差。
        /// 这里改为等比「填充」：先按铺满缩放，再居中裁掉上下多余部分，做到满屏。
        private func fittedImage(_ source: CIImage, width: Int, height: Int) -> CIImage {
            let w = CGFloat(width), h = CGFloat(height)
            if abs(source.extent.width - w) < 1, abs(source.extent.height - h) < 1 { return source }
            let scale = max(w / source.extent.width, h / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // 多出来的高度怎么分配：0 = 全裁顶部（保留底部），1 = 全裁底部（保留顶部），0.5 = 上下均分
            let overflow = scaled.extent.height - h
            let bias: CGFloat = 0.5
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (w - scaled.extent.width) / 2,
                y: -overflow * bias))
            let bounds = CGRect(x: 0, y: 0, width: w, height: h)
            return positioned.composited(over: CIImage(color: .black)).cropped(to: bounds)
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("雅迪\(stage)恢复：\(error.localizedDescription)") }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }

        private func fail(_ error: Error) {
            let message = "雅迪输出失败：\(error.localizedDescription)"
            onLog(message)
            report(message)
            close()
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            timer?.cancel()
            timer = nil
            // 结束握手：NAV_END + 短等 0x23
            if let tcp {
                do {
                    try tcp.write(YadeaProtocol.data(YadeaProtocol.buildFullFrame(
                        type: YadeaProtocol.cmdNavEnd, payload: YadeaProtocol.buildNavEndPayload())))
                    onLog("已发送 NAV_END")
                } catch {}
            }
            tcp?.close()
            tcp = nil
            udp = nil
            rxBuffer.removeAll()
            decoder?.invalidate()
            decoder = nil
            latest = nil
        }
    }
}

// MARK: - 轻量 TCP socket（非阻塞，供控制通道使用）

private enum YadeaError: LocalizedError {
    case closed
    case system(String, Int32)

    var isTransient: Bool {
        guard case .system(_, let code) = self else { return false }
        return code == EAGAIN || code == EWOULDBLOCK || code == EINTR || code == ECONNRESET
    }

    var errorDescription: String? {
        switch self {
        case .closed: return "TCP 已关闭"
        case .system(let op, let code): return "\(op)失败：\(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

private final class YadeaTCPSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    deinit { close() }

    func connect(remoteIP: String, port: UInt16, timeout: TimeInterval = 4) throws {
        close()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw YadeaError.system("创建 TCP", errno) }
        do {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw YadeaError.system("设置 TCP 非阻塞", errno)
            }
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))

            var address = try Self.address(remoteIP, port)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw YadeaError.system("连接 TCP\(port)", errno) }
                try Self.wait(fd, events: Int16(POLLOUT), deadline: Self.now + timeout, operation: "连接 TCP\(port)")
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
                    throw YadeaError.system("读取 TCP 状态", errno)
                }
                guard error == 0 else { throw YadeaError.system("连接 TCP\(port)", error) }
            }
            descriptor = fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func write(_ data: Data, timeout: TimeInterval = 4) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw YadeaError.closed }
        let deadline = Self.now + timeout
        var offset = 0
        while offset < data.count {
            try Self.wait(descriptor, events: Int16(POLLOUT), deadline: deadline, operation: "发送仪表数据")
            let sent = data.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if sent > 0 { offset += sent }
            else if sent == 0 { throw YadeaError.closed }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw YadeaError.system("发送 TCP", errno)
            }
        }
    }

    /// 非阻塞读取可用字节。无数据（超时/EAGAIN）返回 nil，对端关闭抛 closed。
    func readSome(maxBytes: Int, timeoutMs: Int) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw YadeaError.closed }
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&item, 1, Int32(max(1, timeoutMs)))
        if result == 0 { return nil }
        if result < 0 {
            if errno == EINTR { return nil }
            throw YadeaError.system("等待仪表数据", errno)
        }
        if item.revents & Int16(POLLNVAL) != 0 { throw YadeaError.closed }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = Darwin.recv(descriptor, &buffer, maxBytes, 0)
        if n > 0 { return Data(buffer.prefix(n)) }
        if n == 0 { throw YadeaError.closed }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
        throw YadeaError.system("接收 TCP", errno)
    }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval, operation: String) throws {
        while true {
            let remaining = deadline - now
            guard remaining > 0 else { throw YadeaError.system(operation, ETIMEDOUT) }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(max(1, min(50, remaining * 1_000))))
            if result > 0 {
                if item.revents & Int16(POLLNVAL) != 0 { throw YadeaError.closed }
                return
            }
            if result < 0 && errno != EINTR { throw YadeaError.system(operation, errno) }
        }
    }

    private static func address(_ ip: String, _ port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            throw YadeaError.system("解析 IPv4 地址", EINVAL)
        }
        return address
    }
}
