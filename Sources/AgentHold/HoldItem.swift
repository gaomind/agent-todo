import AgentHoldCaptureSupport
import Foundation

typealias HoldProvider = AgentHoldCaptureSupport.HoldProvider

extension HoldProvider {
    var canReopenWithoutTurnID: Bool { self == .claude || self == .gemini }
}

struct CodexReply: Codable, Sendable {
    let sessionID: String
    let turnID: String?
    let cwd: String?
    let message: String
    let receivedAt: Date
    let messageTruncated: Bool?
    let trailingMessage: String?
    private let capturedProvider: HoldProvider?

    var provider: HoldProvider { capturedProvider ?? .codex }

    private enum CodingKeys: String, CodingKey {
        case sessionID, turnID, cwd, message, receivedAt, messageTruncated, trailingMessage
        case capturedProvider = "provider"
    }

    init(sessionID: String, turnID: String? = nil, cwd: String?, message: String, receivedAt: Date,
         messageTruncated: Bool? = nil, trailingMessage: String? = nil, provider: HoldProvider = .codex) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.message = message
        self.receivedAt = receivedAt
        self.messageTruncated = messageTruncated
        self.trailingMessage = trailingMessage
        self.capturedProvider = provider
    }

    var detectedConditions: [String] {
        HoldDetector.conditions(in: message, omittingTrailingClause: messageTruncated == true)
    }
}

enum HoldStatus: String, Codable, CaseIterable, Identifiable {
    case waiting, completed, dismissed

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Older versions saved the now-removed intermediate state as "ready".
        guard let status = Self(rawValue: value == "ready" ? "waiting" : value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown hold status: \(value)")
        }
        self = status
    }

    var id: Self { self }

    var label: String {
        switch self {
        case .waiting: "等待"
        case .completed: "完成"
        case .dismissed: "已忽略"
        }
    }
}

struct HoldItem: Codable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let turnID: String?
    let cwd: String?
    let detectedAt: Date
    var evidence: String
    var condition: String
    var status: HoldStatus
    var wasEdited = false
    var sourceID: UUID? = nil
    var sourceTruncated: Bool? = nil
    var capturedProvider: HoldProvider? = nil
    var closedAt: Date? = nil

    var provider: HoldProvider { capturedProvider ?? .codex }
    var clipboardHeading: String { "\(provider.label) · 待办" }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, turnID, cwd, detectedAt, evidence, condition, status, wasEdited, sourceID, sourceTruncated, closedAt
        case capturedProvider = "provider"
    }

    var project: String {
        guard let cwd, !cwd.isEmpty else { return "未知项目" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var resumeCommand: String {
        let session = sessionID.uuidString.lowercased()
        let quotedPath = cwd.flatMap { path in
            path.hasPrefix("/") ? "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" : nil
        }
        switch provider {
        case .codex:
            return quotedPath.map { "codex -C \($0) resume \(session)" } ?? "codex resume \(session)"
        case .claude:
            return quotedPath.map { "cd \($0) && claude --resume \(session)" } ?? "claude --resume \(session)"
        case .grok:
            return quotedPath.map { "grok --cwd \($0) --resume \(session)" } ?? "grok --resume \(session)"
        case .gemini:
            return quotedPath.map { "cd \($0) && gemini --resume \(session)" } ?? "gemini --resume \(session)"
        case .antigravity:
            return quotedPath.map { "cd \($0) && agy --conversation \(session)" } ?? "agy --conversation \(session)"
        case .unknown:
            return ""
        }
    }

    var resumeContext: String {
        var lines = [clipboardHeading, "", "请接续这项工作。", "恢复条件：\(condition)"]
        if let cwd { lines.append("来源目录：\(cwd)") }
        lines.append("请先核对恢复条件是否已满足，再继续未完成的工作。")
        return lines.joined(separator: "\n")
    }
}

enum HoldDetector {
    static let maximumReplyBytes = 64 * 1024

    private struct Rule: @unchecked Sendable {
        let pattern: Regex<AnyRegexOutput>

        init(_ source: String) {
            do {
                pattern = try Regex(source)
            } catch {
                preconditionFailure("无效的等待识别规则：\(error)")
            }
        }
    }

    private static let waitRules = [
        Rule(#"(?i)^(?:(?:我(?:目前|现在|这边)?(?:还|仍)?(?:在|正|会继续)?等待|等待(?:你|您|审批通过|审核通过|对方回复|系统恢复))|我需要(?:你|您)|(?:我)?(?:还|仍)需要(?:你|您)|(?:我)?(?:暂时)?(?:无法|不能)继续[，,:：；;][ \t]*(?:需要|直到|请)|(?:目前|当前|现在)?(?:卡在|受阻于|阻塞在)|(?:请)?等(?:你|您|审批通过|审核通过|对方|系统恢复)|(?:目前|当前|现在)?(?:需要|须等)(?:你|您|审批通过|审核通过)|(?:待|等)(?:你|您|审批通过|审核通过|对方回复|系统恢复)).{2,}"#),
        Rule(#"(?i)^(?:i(?:'m|’m| am) (?:currently |still )?(?:waiting (?:for|on)|blocked (?:by|on|until))|i (?:need (?:you to|your)|can(?:not|'t|’t) (?:proceed|continue) (?:until|without)|(?:will|'ll|’ll) (?:wait|resume|continue) (?:until|after|once|for))|(?:waiting (?:for|on)|blocked (?:by|on|until))|(?:currently )?pending (?:your|approval|confirmation)|(?:once|after) you .+[,，] (?:i can|i will|i'll|i’ll) (?:resume|continue|proceed))\b.{2,}"#),
        Rule(#"^(?:请|麻烦)(?:你|您)?(?:先)?(?:确认|提供|授权|决定|选择|回复|手动(?:执行|同步|批准|合并)|在.{2,30}(?:同步|授权|操作)).{2,}(?:后(?:我|再)|[，,](?:我再|才能|我才能)).{2,}"#),
        Rule(#"^(?:[^，,]{1,36}[，,]\s*)?(?:等|待).{2,}(?:之后|后)[，,]?(?:我再|我就|我会|再).{2,}"#),
        Rule(#"^(?:请|麻烦)(?:你|您)?(?:先)?(?:确认|提供|授权|决定|选择|回复).{2,}[，,]\s*我(?:再|就|会)(?:先)?(?:继续|检查|处理|验收|开始|执行|创建).{2,}"#),
    ]
    private static let excluded = Rule(
        #"(?i)(?:无需(?:再)?等待|不用(?:再)?等待|无需你|不再等待|不需要(?:你|等待)|如果(?:你|您)(?:愿意|需要|想)|如(?:有需要|果仍需)|可选(?:的)?(?:后续|下一步)|后续建议|仅供参考|already (?:confirmed|approved|provided|verified|completed)|no longer (?:waiting|blocked)|no (?:further )?action (?:is )?required|if (?:you (?:want|would like|wish)|needed)|optional next step|for (?:any )?future (?:deployment|changes|work)|(?:下一阶段|未来|后续)如需)"#
    )
    private static func clauses(in line: String, includeUnterminated: Bool) -> [Substring] {
        var result: [Substring] = []
        var start = line.startIndex
        var index = start
        while index < line.endIndex {
            let separator = index
            let character = line[index]
            line.formIndex(after: &index)
            switch character {
            case "。", "！", "？":
                break
            case ".", "!", "?":
                if character != "." {
                    // English question and exclamation marks are a unit. Skip
                    // the whole run even when it does not end a sentence.
                    while index < line.endIndex, line[index] == "!" || line[index] == "?" {
                        line.formIndex(after: &index)
                    }
                }
                guard index == line.endIndex ? includeUnterminated : line[index].isWhitespace else { continue }
                while index < line.endIndex, line[index].isWhitespace {
                    line.formIndex(after: &index)
                }
            default:
                continue
            }
            if start < separator { result.append(line[start..<separator]) }
            start = index
        }
        if includeUnterminated, start < line.endIndex { result.append(line[start...]) }
        return result
    }

    static func conditions(in message: String, omittingTrailingClause: Bool = false) -> [String] {
        guard message.utf8.count <= maximumReplyBytes else { return [] }
        var conditions: [String] = []
        var insideCodeFence = false
        for line in message.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideCodeFence.toggle()
                continue
            }
            guard !insideCodeFence, !trimmed.hasPrefix(">") else { continue }
            let includeUnterminated = !omittingTrailingClause || line.endIndex != message.endIndex
            for clause in clauses(in: includeUnterminated ? trimmed : String(line),
                                  includeUnterminated: includeUnterminated) {
                let text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^\s*(?:(?:[-*+]\s+)|(?:\d+[.)]\s+)|\*\*|__)+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\*\*|__"#, with: "", options: .regularExpression)
                let condition = text.replacingOccurrences(
                    of: #"(?i)^(?:恢复条件|阻塞原因|等待事项|Waiting for|Blocked on)\s*[:：]\s*"#,
                    with: "", options: .regularExpression
                )
                guard !condition.isEmpty, condition.firstMatch(of: excluded.pattern) == nil,
                      (condition != text || waitRules.contains(where: { text.firstMatch(of: $0.pattern) != nil })) else { continue }
                let evidence = String(condition.prefix(400))
                if !conditions.contains(evidence) { conditions.append(evidence) }
                if conditions.count >= 5 { return conditions }
            }
        }
        return conditions
    }
}
