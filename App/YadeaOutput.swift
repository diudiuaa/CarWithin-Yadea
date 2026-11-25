import CoreImage
import Darwin
import Foundation
import ImageIO

/// 铺满全屏的取景参数。
///
/// 仪表回报的可投区比整块面板矮（800×384 vs 800×480），按「等比铺满 + 居中裁切」送整高，
/// 再用这两个值微调：缩放决定画面放多大，偏移决定裁掉的上边多还是下边多。
struct YadeaFraming: Equatable {
    /// 100 = 刚好铺满目标框；< 100 画面缩小（四周留黑）；> 100 further 放大（裁掉更多）。
    var scalePercent: Int = 100
    /// -100 贴顶、0 居中、100 贴底。
    var verticalPercent: Int = 0

    static let scaleRange = 60...150
    static let verticalRange = -100...100

    var scaleFactor: CGFloat { CGFloat(scalePercent) / 100 }
    /// 0…1：0 保留顶部（裁底部），0.5 上下均分，1 保留底部（裁顶部）。
    var bias: CGFloat { CGFloat(verticalPercent + 100) / 200 }
}

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

    func start(localAddress: String, targetAddress: String, keyMap: YadeaKeyMap,
               framing: YadeaFraming = YadeaFraming(),
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               onKey: @escaping (YadeaKeyAction) -> Void, requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, keyMap: keyMap, framing: framing, onState: onState, onLog: onLog,
                           onKey: onKey, requestKeyframe: requestKeyframe)
        session = next
        queue.async { next.start(localAddress, targetAddress) }
    }

    /// 设置页拖动滑块时实时生效，不必重连。
    func updateFraming(_ framing: YadeaFraming) {
        session?.updateFraming(framing)
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
        let keyMap: YadeaKeyMap
        /// 只在 `queue` 上读写。
        private var framing: YadeaFraming
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let onKey: (YadeaKeyAction) -> Void
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
        private var localAddress = ""
        private var targetAddress = ""
        /// 缓冲里拼不出帧、又一直等不到新字节时的连续等待次数（超过就按垃圾字节处理）。
        private var stallWaits = 0
        private var lastWaitSize = 0

        private var decoder: TailingH264Decoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var fresh = false
        private var lastFrame = -Double.infinity
        private var lastCodecFailure = -Double.infinity

        private var navConfig = NavDisplayConfig()
        /// 同一动作的按下／抬起若各发一帧，150 毫秒内只认一次。
        private var lastActionAt: [String: Double] = [:]
        /// 已经打印过的上行帧，避免未知命令每秒刷屏。
        private var seenTokens: Set<String> = []
        /// 不符合标准帧头／帧尾而被丢弃的字节，用于发现「另一种封装」的按键上报。
        private var droppedBytes: [UInt8] = []
        private var lastDroppedLog = -Double.infinity
        private var imageSequence = 1
        private var nextHeartbeat = 0.0
        private var nextFrameAt = 0.0
        private var status = ""

        /// 仪表面板物理高度。0x20 只回报中间可用的投屏区（800×384），
        /// 上下各 48px 由仪表绘制状态栏与 Logo；整块面板实际是 800×480。
        /// 实验：按整高投送，验证仪表是否支持把这两条半透明叠加在画面上。
        private let panelHeight = 480

        private enum Phase { case connecting, negotiating, running, waiting }
        private var phase = Phase.connecting
        private var negotiatedAt = 0.0
        /// 自动重连：仪表断电或 Wi-Fi 切换后不结束会话，退避重试直到重新接上。
        private var attempt = 0
        private var retryDelay = 2.0
        private var retryAt = 0.0

        init(queue: DispatchQueue, keyMap: YadeaKeyMap, framing: YadeaFraming,
             onState: @escaping (String) -> Void,
             onLog: @escaping (String) -> Void, onKey: @escaping (YadeaKeyAction) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.keyMap = keyMap
            self.framing = framing
            self.onState = onState
            self.onLog = onLog
            self.onKey = onKey
            self.requestKeyframe = requestKeyframe
        }

        func updateFraming(_ framing: YadeaFraming) {
            queue.async { [weak self] in
                guard let self, self.framing != framing else { return }
                self.framing = framing
                self.fresh = true
            }
        }

        func start(_ local: String, _ target: String) {
            guard active else { return }
            localAddress = local
            targetAddress = target
            report("正在连接雅迪仪表…")
            timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
            beginAttempt()
        }

        /// 一次连接尝试。失败不结束会话，退到 waiting 相位等下一次 —— 车上电、Wi-Fi 恢复后自动接上。
        private func beginAttempt() {
            guard active, !targetAddress.isEmpty else { return }
            closeSockets()
            // Wi-Fi 可能已经切换（家里 ↔ 仪表热点），每次都用当前地址重建套接字。
            if let current = ReceiverConfiguration.wifiIPv4Address() { localAddress = current }
            do {
                udp = try NinebotUDPSocket(localIP: localAddress, localPort: 0,
                                           remoteIP: targetAddress, remotePort: YadeaProtocol.imagePort)
                let control = YadeaTCPSocket()
                try control.connect(remoteIP: targetAddress, port: YadeaProtocol.controlPort)
                tcp = control
                onLog(attempt == 0
                      ? "雅迪：TCP 8888 控制 + UDP 8889 图片 · JPEG 分片"
                      : "雅迪：已重新连上仪表（第 \(attempt) 次尝试）")
                // 启动序列：HEARTBEAT + NAV_START 合并一条 TCP 发送
                let startup = YadeaProtocol.buildFullFrame(type: YadeaProtocol.cmdHeartbeat,
                                                           payload: YadeaProtocol.buildHeartbeatPayload())
                    + YadeaProtocol.buildFullFrame(type: YadeaProtocol.cmdNavStart,
                                                   payload: YadeaProtocol.buildNavStartPayload())
                try control.write(YadeaProtocol.data(startup))
                phase = .negotiating
                negotiatedAt = ProcessInfo.processInfo.systemUptime
                report(attempt == 0 ? "已发送握手命令，等待仪表回应…" : "已重新握手，等待仪表回应…")
                attempt += 1
                retryDelay = 2
            } catch {
                fail(error)
            }
        }

        /// 连不上或中途断开：不停止会话，按 2→15 秒退避重试。
        private func scheduleRetry(_ error: Error?) {
            phase = .waiting
            closeSockets()
            let now = ProcessInfo.processInfo.systemUptime
            retryAt = now + retryDelay
            if let error { onLog("雅迪输出中断：\(error.localizedDescription)") }
            report("等待仪表上线 · \(Int(retryDelay)) 秒后重试（已尝试 \(attempt) 次）")
            retryDelay = min(retryDelay * 1.6, 15)
            attempt += 1
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
                drainIncoming()
                if now - negotiatedAt > 4 {
                    // 未收到 0x20，按默认 800×480@10 继续（YuRong 同款兜底）
                    onLog("未收到 0x20 配置，使用默认 \(navConfig.summary)")
                    beginRunning(now: now)
                }
            case .running:
                // 投屏期间也要持续收包：仪表可能在此时上报按键（车把按键 → CarPlay）。
                drainIncoming()
                runFrameAndHeartbeat(now: now)
            case .waiting:
                if now >= retryAt { beginAttempt() }
            }
        }

        private func drainIncoming() {
            guard let tcp else { return }
            do {
                while let chunk = try tcp.readSome(maxBytes: 4096, timeoutMs: 0) {
                    rxBuffer.append(contentsOf: YadeaProtocol.bytes(chunk))
                }
                while let frame = nextBufferedFrame() {
                    handle(type: frame.type, payload: frame.payload)
                }
                flushDroppedBytes()
            } catch {
                // 仪表断电／Wi-Fi 断开：进入自动重连，而不是把整个会话结束掉。
                scheduleRetry(error)
            }
        }

        private func handle(type: UInt8, payload: [UInt8]) {
            switch type {
            case YadeaProtocol.cmdNavStartResponse:
                navConfig = YadeaProtocol.parseNavDisplayConfig(payload)
                onLog("协商成功：\(navConfig.summary)，capability=0x\(String(format: "%02X", navConfig.capabilities))")
                report("仪表已回应，正在投屏 · \(navConfig.summary)")
                beginRunning(now: ProcessInfo.processInfo.systemUptime)
            case YadeaProtocol.cmdNavEndResponse, YadeaProtocol.cmdStatusResponse, YadeaProtocol.cmdRateResponse:
                // 仪表可能把按键塞在这些「应答」类型里（0x25 的 payload 每次不同），
                // 所以先过一遍用户映射，命中了就执行，不命中才当状态记一行。
                if fireKey(type: type, payload: payload) { return }
                let token = YadeaKeyMap.token(type: type, payload: payload, limit: 12)
                if seenTokens.insert(token).inserted { onLog("仪表上报 \(token)（结束／状态／帧率应答）") }
            default:
                handleUnmapped(type: type, payload: payload)
            }
        }

        /// 把无法组成标准帧的字节集中报一次。仪表若用别的封装回传按键，会在这里露出来。
        private func flushDroppedBytes() {
            guard !droppedBytes.isEmpty else { return }
            let sample = droppedBytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            let count = droppedBytes.count
            droppedBytes.removeAll()
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastDroppedLog >= 3 else { return }
            lastDroppedLog = now
            let token = "RAW " + sample
            guard seenTokens.insert(token).inserted else { return }
            onLog("仪表原始数据 \(sample)（\(count) 字节，非标准帧）")
        }

        /// 未知命令：命中用户配置的按键映射就转成 CarPlay 动作，否则打印一次供用户填写。
        private func handleUnmapped(type: UInt8, payload: [UInt8]) {
            if fireKey(type: type, payload: payload) { return }
            let token = YadeaKeyMap.token(type: type, payload: payload, limit: 12)
            guard seenTokens.insert(token).inserted else { return }
            onLog("仪表上行 \(token)（未映射：把这串填进「仪表按键」里对应动作即可）")
        }

        /// 命中用户映射就执行并返回 true；150 毫秒内同一动作只认一次。
        @discardableResult
        private func fireKey(type: UInt8, payload: [UInt8]) -> Bool {
            guard let action = keyMap.match(type: type, payload: payload) else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastActionAt[action.rawValue, default: -1] < 0.15 { return true }
            lastActionAt[action.rawValue] = now
            onLog("仪表按键 \(YadeaKeyMap.token(type: type, payload: payload, limit: 12)) → \(action.title)")
            onKey(action)
            return true
        }

        private func magicPosition() -> Int? {
            guard rxBuffer.count >= 2 else { return nil }
            for i in 0...(rxBuffer.count - 2) where rxBuffer[i] == 0x59 && rxBuffer[i + 1] == 0x44 { return i }
            return nil
        }

        /// 拼不成帧时把整段字节打出来。
        ///
        /// 原来只打前 16 个字节，而一帧 23 字节，正好把尾部关键字段截断，
        /// 造成「看到半帧也不知道是什么」；现在最多打 96 字节，并带上长度字段与协议字。
        private func rejectFrame(_ bytes: [UInt8], declared: Int, protocolID: UInt8) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastDroppedLog >= 1 else { return }
            let hex = bytes.prefix(96).map { String(format: "%02X", $0) }.joined(separator: " ")
            guard seenTokens.insert("REJ " + hex).inserted else { return }
            lastDroppedLog = now
            onLog("仪表原始数据 \(hex)（\(bytes.count) 字节，长度字段 \(declared)，协议字 0x\(String(format: "%02X", protocolID))，未解析）")
        }

        /// 从缓冲中扫描魔数 5944 解析出一帧，解析到即返回并移除。
        ///
        /// 长度字段有两种写法：本机发出的帧把 SUM8 与 4B4A 一起计入（内容 + 3），
        /// 仪表自己发的帧只计入 SUM8（内容 + 1）。早先只按前者解析，
        /// 仪表上行的 0x25 之类会被整帧判成「非标准帧」丢弃，按键永远是空的。
        /// 现在两种长度都试，谁的尾标 4B4A 对得上就按谁切帧。
        private func nextBufferedFrame() -> (type: UInt8, payload: [UInt8])? {
            while rxBuffer.count >= 12 {
                guard let pos = magicPosition() else { noteDropped(rxBuffer[...]); rxBuffer.removeAll(); return nil }
                if pos > 0 { noteDropped(rxBuffer[0..<pos]); rxBuffer.removeFirst(pos) }
                guard rxBuffer.count >= 7 else { return nil }

                let protocolID = rxBuffer[2]
                let declared = Int(YadeaProtocol.readUInt32BE(rxBuffer, offset: 3))
                guard declared >= 1, declared <= 1_048_576 else { rxBuffer.removeFirst(); continue }

                let totals = [declared + 7, declared + 9].filter { $0 >= 10 }
                if let total = totals.first(where: {
                    $0 <= rxBuffer.count && rxBuffer[$0 - 2] == 0x4B && rxBuffer[$0 - 1] == 0x4A
                }) {
                    let frame = Array(rxBuffer[0..<total])
                    rxBuffer.removeFirst(total)
                    if let inner = YadeaProtocol.parseInnerPacket(Array(frame[7..<(frame.count - 3)])) {
                        return (inner.type, inner.payload)
                    }
                    // 尾标对上了但内层读不出来：整帧留证，继续找下一帧
                    rejectFrame(frame, declared: declared, protocolID: protocolID)
                    continue
                }

                // 还差字节就等下一批（TCP 可能把一帧拆成两次到达）；
                // 但如果反复等不到新字节，说明这串永远拼不成帧，当垃圾字节打出来。
                if let longest = totals.max(), rxBuffer.count < longest {
                    stallWaits = lastWaitSize == rxBuffer.count ? stallWaits + 1 : 0
                    lastWaitSize = rxBuffer.count
                    if stallWaits < 25 { return nil }
                }
                stallWaits = 0
                lastWaitSize = 0
                let dumpLength = min(max(totals.min() ?? 12, 12), rxBuffer.count, 96)
                rejectFrame(Array(rxBuffer[0..<dumpLength]), declared: declared, protocolID: protocolID)
                rxBuffer.removeFirst(1)
            }
            return nil
        }

        /// 汇总被丢弃的非帧字节（最多留 64 个，避免无限增长）。
        private func noteDropped(_ bytes: ArraySlice<UInt8>) {
            guard droppedBytes.count < 64 else { return }
            droppedBytes.append(contentsOf: bytes.prefix(64 - droppedBytes.count))
        }

        private func beginRunning(now: Double) {
            phase = .running
            lock.withLock { acceptingFrames = true }
            nextFrameAt = now
            nextHeartbeat = now
            let zoom = framing.scalePercent == 100 ? "" : " · 缩放 \(framing.scalePercent)%"
            report("正在投屏 · \(navConfig.width)×\(panelHeight)（铺满）· JPEG\(zoom)")
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
            // 实验：仪表 0x20 回报的投屏区高度是 384（上下各留 48px 画状态栏和 Logo），
            // 但官方投屏时这两条是半透明叠加在画面上的，说明投屏层其实能铺满 480。
            // 这里忽略回报高度，按物理面板整高投送，验证仪表是否支持全屏模式。
            let targetHeight = panelHeight
            guard let jpeg = encodeJPEG(latest, width: navConfig.width, height: targetHeight) else { return }
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
            catch {
                // 网络切换（家里换公司、切热点、后台回来）后旧的 UDP socket 还绑在失效的本机地址上，
                // 发送会直接返回 EADDRNOTAVAIL(49)。这里原地重开图片通道，不用手动重连。
                if isAddressLost(error), rebuildUDP() {
                    onLog("雅迪：本机地址已变化，已重开图片通道，继续投屏")
                    nextFrameAt = now + Double(navConfig.frameIntervalMs) / 1000.0
                    return
                }
                fail(error)
            }
        }

        /// 旧的 UDP socket 绑在已失效的本机地址上时，发送会返回 EADDRNOTAVAIL(49)。
        private func isAddressLost(_ error: Error) -> Bool {
            guard case .operation(_, let code)? = error as? NinebotSocketError else { return false }
            return code == EADDRNOTAVAIL || code == ENETDOWN || code == ENETUNREACH
        }

        /// 重开图片通道：先试原本机地址，再试 0.0.0.0（交给内核按路由选源地址）。
        private func rebuildUDP() -> Bool {
            guard !targetAddress.isEmpty else { return false }
            // 换了 Wi-Fi 之后本机地址会变，重开前先取一次当前地址。
            if let current = ReceiverConfiguration.wifiIPv4Address() { localAddress = current }
            for local in [localAddress, "0.0.0.0"] where !local.isEmpty {
                if let socket = try? NinebotUDPSocket(localIP: local, localPort: 0,
                                                      remoteIP: targetAddress,
                                                      remotePort: YadeaProtocol.imagePort) {
                    udp = socket
                    return true
                }
            }
            return false
        }

        // MARK: - JPEG 编码

        private func encodeJPEG(_ image: CVPixelBuffer, width: Int, height: Int) -> Data? {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            func jpeg(_ source: CIImage, _ quality: Int) -> Data? {
                compositor.jpegRepresentation(of: source, colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: CGFloat(quality) / 100])
            }
            let fitted = fittedImage(CIImage(cvPixelBuffer: image), width: width, height: height, framing: framing)
            // Auto 画质：大图用 72，超硬上限 80KB 时降质重试一次（YuRong 同款策略）
            if let first = jpeg(fitted, 72), first.count <= YadeaProtocol.imageHardLimit { return first }
            if let retried = jpeg(fitted, 64) { return retried }
            return nil
        }

        /// 铺满目标区域后按取景参数裁切，避免黑边；滑块可微调缩放与上下位置。
        ///
        /// 仪表屏可投区是 800×384（≈2.08:1），而 CarPlay 请求的是 800×480（16:9），
        /// 等比「适配」会在左右各留 80px 黑边（合计占宽 20%），观感很差。
        /// 这里按「填充」缩放（`max`）后再裁，基准比例就是铺满；缩放滑块在此基础上再放大或缩小，
        /// 上下偏移滑块决定溢出的高度保留顶部还是底部。
        private func fittedImage(_ source: CIImage, width: Int, height: Int, framing: YadeaFraming) -> CIImage {
            let w = CGFloat(width), h = CGFloat(height)
            let scale = max(w / source.extent.width, h / source.extent.height) * framing.scaleFactor
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let overflowY = scaled.extent.height - h
            // 溢出时按偏移比例分配；缩得比目标框还小时（溢出为负）让它在垂直方向居中。
            let offsetY = overflowY > 0 ? -overflowY * framing.bias : overflowY / 2
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (w - scaled.extent.width) / 2,
                y: offsetY))
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
            scheduleRetry(error)
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
            closeSockets()
        }

        /// 只回收套接字与解码器，保留定时器和会话 —— 自动重连靠它在原地开新通道。
        private func closeSockets() {
            tcp?.close()
            tcp = nil
            udp = nil
            rxBuffer.removeAll()
            stallWaits = 0
            lastWaitSize = 0
            decoder?.invalidate()
            decoder = nil
            waitingForIDR = true
            latest = nil
            fresh = false
            lock.withLock { decoded = nil; decodeError = nil }
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
