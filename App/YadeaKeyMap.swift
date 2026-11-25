import Foundation

/// 仪表物理按键能触发的 CarPlay 动作。
enum YadeaKeyAction: String, CaseIterable {
    case up, down, left, right, select, back, home

    var title: String {
        switch self {
        case .up: return CWL("拨轮向上")
        case .down: return CWL("拨轮向下")
        case .left: return CWL("上一页（左滑）")
        case .right: return CWL("下一页（右滑）")
        case .select: return CWL("确认")
        case .back: return CWL("返回")
        case .home: return CWL("主页")
        }
    }

    /// UserDefaults 里保存十六进制模式的键名。
    var storageKey: String { "yadeaKey." + rawValue }
}

/// 把仪表上行帧映射成动作。
///
/// 雅迪没有公开「仪表 → 手机」的按键回传格式，所以这里不写死码值：
/// 用户投屏时按下车把／仪表按键，日志会打出上行帧的十六进制串，
/// 把那一串填进对应动作的输入框就能立刻生效，不必重新编译。
struct YadeaKeyMap {
    /// 动作 → 字节模式；匹配上行帧 `type + payload` 的前缀。
    private(set) var patterns: [(action: YadeaKeyAction, bytes: [UInt8])] = []

    init(raw: [String: String]) {
        for action in YadeaKeyAction.allCases {
            guard let text = raw[action.rawValue], let bytes = Self.parse(text), !bytes.isEmpty else { continue }
            patterns.append((action, bytes))
        }
    }

    var isEmpty: Bool { patterns.isEmpty }

    /// `1A 01 00`、`0x1a,0x01`、`1a0100` 都接受；非法或奇数长度返回 nil。
    static func parse(_ text: String) -> [UInt8]? {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "0x", with: "")
            .components(separatedBy: CharacterSet(charactersIn: " ,;|-\t\r\n"))
            .joined()
        guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.isEmpty ? nil : bytes
    }

    /// 上行帧是否命中某个动作。命令字节在前，因此模式至少要写两位。
    func match(type: UInt8, payload: [UInt8]) -> YadeaKeyAction? {
        let frame = [type] + payload
        return patterns.first { pattern in
            frame.count >= pattern.bytes.count && Array(frame.prefix(pattern.bytes.count)) == pattern.bytes
        }?.action
    }

    /// 把上行帧转成可直接填进映射框的字符串，例如 `1A 01 00`。
    static func token(type: UInt8, payload: [UInt8], limit: Int = 8) -> String {
        ([type] + payload.prefix(max(0, limit - 1))).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
