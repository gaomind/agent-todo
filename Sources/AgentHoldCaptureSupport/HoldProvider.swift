public enum HoldProvider: String, Codable, Sendable {
    case codex, claude, grok, gemini, antigravity, unknown

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .grok: "Grok"
        case .gemini: "Gemini CLI"
        case .antigravity: "Antigravity CLI"
        case .unknown: "未知来源"
        }
    }

    public var label: String {
        switch self {
        case .codex: "⌘ Codex"
        case .claude: "✳ Claude Code"
        case .grok: "◉ Grok"
        case .gemini: "✦ Gemini CLI"
        case .antigravity: "✧ Antigravity CLI"
        case .unknown: "◇ 未知来源"
        }
    }
}
