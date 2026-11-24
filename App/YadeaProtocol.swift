import Foundation

/// 雅迪（Yadea）仪表投屏协议。
///
/// 逆向来源：YuRong（Nuni-Zixi/YuRong）对「雅迪智行 SmartMoto」base.apk 的协议还原，
/// 帧格式与校验算法均以能正常投屏的 base.apk 为兼容基准。
///
/// 两层帧结构：
/// ```
/// 外层: 59 44 | 3C | INNER_LEN(BE32) | INNER_PACKET | SUM8 | 4B 4A
/// 内层: TYPE(1B) | PAYLOAD_LEN(BE32) | PAYLOAD
/// ```
/// 校验和 SUM8 覆盖 3C + INNER_LEN + INNER_PACKET，不覆盖 59 44 和 4B 4A。
/// 传输：TCP 8888 控制通道 + UDP 8889 图片通道（图片按 1434 字节分片走 UDP）。
enum YadeaProtocol {
    // MARK: - 内层命令字

    static let cmdNavStart: UInt8 = 0x10        // 导航启动请求
    static let cmdNavEnd: UInt8 = 0x13          // 导航结束请求
    static let cmdNavInfo: UInt8 = 0x14         // 导航信息（64 字节二进制）
    static let cmdLaneInfo: UInt8 = 0x15        // 车道信息
    static let cmdSegmentProgress: UInt8 = 0x16 // 路段进度
    static let cmdImageChunk: UInt8 = 0x12      // 导航图片块（base.apk 兼容命令）
    static let cmdImageChunkAlt: UInt8 = 0x1A   // 新版 NaviSendManager 命令
    static let cmdHeartbeat: UInt8 = 0x1F       // 时间同步/心跳

    static let cmdNavStartResponse: UInt8 = 0x20
    static let cmdNavEndResponse: UInt8 = 0x23
    static let cmdStatusResponse: UInt8 = 0x25
    static let cmdRateResponse: UInt8 = 0x26

    // MARK: - 参数

    static let chunkSize = 1434                 // 0x59A，图片分片大小
    static let imageTargetMin = 30_720          // 0x7800，目标最小 30KB
    static let imageTargetMax = 51_200          // 0xC800，目标最大 50KB
    static let imageHardLimit = 81_920          // 0x14000，硬上限 80KB

    /// 控制通道（TCP）端口
    static let controlPort: UInt16 = 8888
    /// 图片通道（UDP）端口
    static let imagePort: UInt16 = 8889

    static let defaultWidth = 800
    static let defaultHeight = 480
    static let defaultFps = 10

    // MARK: - 外层帧构建

    private static let frameHead: [UInt8] = [0x59, 0x44] // "YD"
    private static let protocolID: UInt8 = 0x3C
    private static let frameTail: [UInt8] = [0x4B, 0x4A] // "KJ"

    /// 构建内层包：TYPE(1B) + PAYLOAD_LEN(BE32) + PAYLOAD
    static func buildInnerPacket(type: UInt8, payload: [UInt8]) -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: 5 + payload.count)
        inner[0] = type
        writeUInt32BE(&inner, offset: 1, value: UInt32(payload.count))
        inner.replaceSubrange(5..., with: payload)
        return inner
    }

    /// 构建完整外层帧：5944 + 3C + INNER_LEN(BE32) + INNER_PACKET + SUM8 + 4B4A
    static func buildFrame(innerPacket: [UInt8]) -> [UInt8] {
        let innerLen = innerPacket.count + 3
        var frame = [UInt8](repeating: 0, count: innerPacket.count + 10)
        var pos = 0
        frame.replaceSubrange(0..<2, with: frameHead); pos += 2
        frame[pos] = protocolID; pos += 1
        writeUInt32BE(&frame, offset: pos, value: UInt32(innerLen)); pos += 4
        frame.replaceSubrange(pos..<(pos + innerPacket.count), with: innerPacket); pos += innerPacket.count

        // 校验和 SUM8：从 protocolID（offset 2）到 innerPacket 结束
        var sum = 0
        for i in 2..<pos { sum += Int(frame[i]) }
        frame[pos] = UInt8(sum & 0xFF); pos += 1
        frame.replaceSubrange(pos..<(pos + 2), with: frameTail)
        return frame
    }

    /// 构建完整帧（内层 + 外层）
    static func buildFullFrame(type: UInt8, payload: [UInt8]) -> [UInt8] {
        buildFrame(innerPacket: buildInnerPacket(type: type, payload: payload))
    }

    // MARK: - 帧解析

    /// 解析外层帧 → (innerPacket, totalFrameLen)
    static func parseOuterFrame(_ data: [UInt8]) -> (inner: [UInt8], length: Int)? {
        guard data.count >= 12, data[0] == 0x59, data[1] == 0x44 else { return nil }
        let innerLen = Int(readUInt32BE(data, offset: 3))
        guard innerLen >= 3, innerLen <= 1_048_576 else { return nil }
        let totalFrameLen = innerLen + 7
        guard data.count >= totalFrameLen else { return nil }
        guard data[totalFrameLen - 2] == 0x4B, data[totalFrameLen - 1] == 0x4A else { return nil }
        let inner = Array(data[7..<(totalFrameLen - 3)])
        return (inner, totalFrameLen)
    }

    /// 解析内层包 → (type, payload, innerPacketLength)
    static func parseInnerPacket(_ inner: [UInt8]) -> (type: UInt8, payload: [UInt8], length: Int)? {
        guard inner.count >= 5 else { return nil }
        let type = inner[0]
        let payloadLen = Int(readUInt32BE(inner, offset: 1))
        guard payloadLen >= 0, 5 + payloadLen <= inner.count else { return nil }
        return (type, Array(inner[5..<(5 + payloadLen)]), 5 + payloadLen)
    }

    /// 完整解析：外层 → 内层，返回 (type, payload, frameLength)
    static func parseFrame(_ data: [UInt8]) -> (type: UInt8, payload: [UInt8], length: Int)? {
        guard let outer = parseOuterFrame(data) else { return nil }
        guard let inner = parseInnerPacket(outer.inner) else { return nil }
        return (inner.type, inner.payload, outer.length)
    }

    // MARK: - 导航控制 payload

    /// 0x10 导航启动请求 payload：8 字节固定 `05 9A F0 FF 00 00 05 9A`
    static func buildNavStartPayload() -> [UInt8] {
        [0x05, 0x9A, 0xF0, 0xFF, 0x00, 0x00, 0x05, 0x9A]
    }

    /// 0x13 导航结束请求 payload：8 字节固定 `02 FF FF FF FF FF FF FF`
    static func buildNavEndPayload() -> [UInt8] {
        [0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    }

    /// 0x1F 心跳 payload：8 字节 `[year%100, month, day, hour, minute, second, FF, FF]`
    static func buildHeartbeatPayload(date: Date = Date()) -> [UInt8] {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return [
            UInt8((c.year ?? 0) % 100), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
            UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
            0xFF, 0xFF
        ]
    }

    // MARK: - 图片分块

    /// 0x12/0x1A 图片块 payload：
    /// [0:2] CRC16（低字节在前）· [2:4] chunkLen(BE16) · [4:8] imageSeq(BE32) ·
    /// [8:12] totalSize(BE32) · [12:16] offset=chunkIndex*1434(BE32) · [16:20] timestamp(BE32) · [20:] chunk
    static func buildImageChunkPayload(crc16: Int, chunkLen: Int, imageSeq: Int, totalSize: Int,
                                       chunkIndex: Int, chunk: [UInt8], timestamp: UInt32) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 20 + chunk.count)
        payload[0] = UInt8(crc16 & 0xFF)
        payload[1] = UInt8((crc16 >> 8) & 0xFF)
        writeUInt16BE(&payload, offset: 2, value: UInt16(chunkLen))
        writeUInt32BE(&payload, offset: 4, value: UInt32(imageSeq))
        writeUInt32BE(&payload, offset: 8, value: UInt32(totalSize))
        writeUInt32BE(&payload, offset: 12, value: UInt32(chunkIndex * chunkSize))
        writeUInt32BE(&payload, offset: 16, value: timestamp)
        payload.replaceSubrange(20..., with: chunk)
        return payload
    }

    /// 将整张图片分块为完整帧列表（每片外层帧内含 0x12 图片块命令）
    static func buildImageFrames(image: [UInt8], imageSeq: Int, timestamp: UInt32,
                                 command: UInt8 = cmdImageChunk) -> [[UInt8]] {
        let crc = crc16Ibm(image)
        var frames: [[UInt8]] = []
        var chunkIndex = 0
        var offset = 0
        while offset < image.count {
            let len = min(chunkSize, image.count - offset)
            let chunk = Array(image[offset..<(offset + len)])
            let payload = buildImageChunkPayload(crc16: crc, chunkLen: len, imageSeq: imageSeq,
                                                 totalSize: image.count, chunkIndex: chunkIndex,
                                                 chunk: chunk, timestamp: timestamp)
            frames.append(buildFullFrame(type: command, payload: payload))
            offset += len
            chunkIndex += 1
        }
        return frames
    }

    // MARK: - CRC16-IBM/ARC

    /// 图片整图 CRC16：poly=0xA001，init=0xFFFF，输入低 bit 优先，无 final XOR。
    static func crc16Ibm(_ data: [UInt8]) -> Int {
        var crc = 0xFFFF
        for byte in data {
            crc ^= Int(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc & 0xFFFF
    }

    // MARK: - 显示配置解析

    /// 0x20 启动响应 payload：
    /// [0:2] width(BE16) · [2:4] height(BE16) · [4] format(>2 归 0) · [6] capability · [7] rate(1..30 否则 10)
    static func parseNavDisplayConfig(_ data: [UInt8]) -> NavDisplayConfig {
        guard data.count >= 8 else { return NavDisplayConfig() }
        let width = Int(readUInt16BE(data, offset: 0))
        let height = Int(readUInt16BE(data, offset: 2))
        let format = Int(data[4]) > 2 ? 0 : Int(data[4])
        let capability = Int(data[6])
        let rate = Int(data[7])
        return NavDisplayConfig(
            width: (320...4096).contains(width) ? width : defaultWidth,
            height: (160...2160).contains(height) ? height : defaultHeight,
            imageFormat: format,
            capabilities: capability,
            maxFps: (1...30).contains(rate) ? rate : defaultFps
        )
    }

    // MARK: - 大端读写工具

    static func writeUInt16BE(_ bytes: inout [UInt8], offset: Int, value: UInt16) {
        bytes[offset] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    static func writeUInt32BE(_ bytes: inout [UInt8], offset: Int, value: UInt32) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    static func readUInt16BE(_ bytes: [UInt8], offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func readUInt32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    // MARK: - Data 便捷转换

    static func bytes(_ data: Data) -> [UInt8] { [UInt8](data) }
    static func data(_ bytes: [UInt8]) -> Data { Data(bytes) }
}

/// 雅迪 0x20 启动响应解析出的显示配置。
struct NavDisplayConfig: Equatable {
    var width = YadeaProtocol.defaultWidth
    var height = YadeaProtocol.defaultHeight
    var imageFormat = 0
    var capabilities = 0
    var maxFps = YadeaProtocol.defaultFps

    var frameIntervalMs: Int {
        (1_000 + maxFps - 1) / maxFps
    }

    var summary: String {
        "\(width)×\(height) · \(maxFps) FPS"
    }
}
