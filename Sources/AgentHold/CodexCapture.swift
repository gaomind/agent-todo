import AgentHoldCaptureSupport
import Combine
import Foundation

@MainActor
final class CodexCapture: ObservableObject {
    typealias ReplyHandler = @MainActor (CodexReply, [String]) -> Bool

    @Published private(set) var statusMessage = "正在启动回复监听…"
    @Published private var receipts: [HoldProvider: Date] = [:]

    var lastOrdinaryReceivedAt: Date? { lastReceivedAt(for: .codex) }

    func lastReceivedAt(for provider: HoldProvider) -> Date? {
        receipts[provider]
    }

    private let consumeProbe: ReplyHandler?
    private let onReply: ReplyHandler
    private let spool: ReplySpool
    private var listener: Task<Void, Never>?

    init(spool: ReplySpool = ReplySpool(), consumeProbe: ReplyHandler? = nil, onReply: @escaping ReplyHandler) {
        self.spool = spool
        self.consumeProbe = consumeProbe
        self.onReply = onReply
    }

    deinit {
        listener?.cancel()
    }

    func start() {
        guard listener == nil else { return }
        statusMessage = "正在监听本地对话回复。首次使用请配置回复源。"
        let spool = self.spool
        listener = Task.detached(priority: .utility) { [weak self] in
            let decoder = JSONDecoder()
            while !Task.isCancelled {
                var delay: Duration = .seconds(1)
                do {
                    let entries = try spool.pending()
                    var processed: [ReplySpool.Entry] = []
                    for entry in entries {
                        guard !Task.isCancelled else { break }
                        if let data = entry.data,
                           let reply = try? decoder.decode(CodexReply.self, from: data) {
                            let conditions = reply.detectedConditions
                            guard await self?.deliver(reply, conditions: conditions) == true else { break }
                        }
                        processed.append(entry)
                    }
                    if !processed.isEmpty {
                        try spool.remove(processed)
                    }
                    if !entries.isEmpty && processed.count == entries.count {
                        delay = .milliseconds(100)
                    }
                    await self?.clearListenerError()
                } catch {
                    await self?.showListenerError(error.localizedDescription)
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stop() async {
        listener?.cancel()
        await listener?.value
        listener = nil
    }

    private func deliver(_ reply: CodexReply, conditions: [String]) -> Bool {
        guard !Task.isCancelled else { return false }
        guard reply.provider != .unknown else { return true }
        if reply.provider == .codex, consumeProbe?(reply, conditions) == true { return true }
        if UUID(uuidString: reply.sessionID) != nil,
           lastReceivedAt(for: reply.provider).map({ reply.receivedAt > $0 }) ?? true {
            receipts[reply.provider] = reply.receivedAt
        }
        return onReply(reply, conditions)
    }

    private func showListenerError(_ description: String) {
        statusMessage = "回复队列读取失败，将重试。\(description)"
    }

    private func clearListenerError() {
        if statusMessage.hasPrefix("回复队列读取失败") {
            statusMessage = "已恢复监听本地对话回复。"
        }
    }
}

enum CodexHookConfiguration {
    private static let argument = "--agent-hold-stop-hook"
    private static let maximumConfigurationBytes = 1024 * 1024

    static func command(for executable: URL) -> String {
        "exec \(shellQuote(executable.path)) \(argument)"
    }

    static func install(at file: URL, executable: URL) throws {
        let manager = FileManager.default
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              manager.isExecutableFile(atPath: executable.path) else {
            throw ConfigurationError.hookMissing
        }
        let command = command(for: executable)
        let original = try read(file)
        var root: [String: Any] = [:]
        if let original {
            guard let parsed = try? JSONSerialization.jsonObject(with: original),
                  let dictionary = parsed as? [String: Any],
                  dictionary.keys.allSatisfy({ $0 == "description" || $0 == "hooks" }),
                  validOptionalString(dictionary["description"]) else {
                throw ConfigurationError.invalidStructure
            }
            root = dictionary
        }
        var events: [String: Any] = [:]
        if let existing = root["hooks"] {
            guard let dictionary = existing as? [String: Any] else {
                throw ConfigurationError.invalidStructure
            }
            events = dictionary
        }

        try validateEvents(events)
        var stopGroups = events["Stop"] as? [[String: Any]] ?? []
        var matchingGroups: [Int] = []
        for (index, group) in stopGroups.enumerated() {
            let hooks = group["hooks"] as? [[String: Any]] ?? []
            for handler in hooks {
                guard let existing = handler["command"] as? String else { continue }
                if existing == command || isManaged(existing) {
                    guard hooks.count == 1, handler["type"] as? String == "command" else {
                        throw ConfigurationError.invalidStructure
                    }
                    matchingGroups.append(index)
                }
            }
        }
        guard matchingGroups.count <= 1 else { throw ConfigurationError.invalidStructure }
        if let index = matchingGroups.first {
            guard var handlers = stopGroups[index]["hooks"] as? [[String: Any]],
                  let previous = handlers[0]["command"] as? String else {
                throw ConfigurationError.invalidStructure
            }
            if previous == command { return }
            handlers[0]["command"] = command
            stopGroups[index]["hooks"] = handlers
        } else {
            stopGroups.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
        }
        events["Stop"] = stopGroups
        root["hooks"] = events
        var replacement = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        replacement.append(0x0A)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try read(file) == original else { throw ConfigurationError.concurrentChange }
        if original == nil {
            // Publish a complete file without replacing a concurrent first writer.
            let temporary = file.deletingLastPathComponent().appendingPathComponent(".AgentHold-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: temporary) }
            try replacement.write(to: temporary, options: .withoutOverwriting)
            try manager.linkItem(at: temporary, to: file)
        } else {
            try replacement.write(to: file, options: .atomic)
        }
    }

    private static let knownEvents: Set<String> = [
        "PreModelRequest", "PostModelRequest", "PreToolUse", "PermissionRequest",
        "PostToolUse", "PreCompact", "PostCompact", "SessionStart", "SessionEnd",
        "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "Interrupt",
    ]

    private static func validateEvents(_ events: [String: Any]) throws {
        for (event, value) in events where knownEvents.contains(event) {
            guard let groups = value as? [[String: Any]] else {
                throw ConfigurationError.invalidStructure
            }
            for group in groups {
                guard validOptionalString(group["matcher"]) else {
                    throw ConfigurationError.invalidStructure
                }
                guard let handlers = group["hooks"] else { continue }
                guard let hooks = handlers as? [[String: Any]], hooks.allSatisfy(validHandler) else {
                    throw ConfigurationError.invalidStructure
                }
            }
        }
    }

    private static func validHandler(_ definition: [String: Any]) -> Bool {
        switch definition["type"] as? String {
        case "command":
            return definition["command"] is String
        case "mcp_tool":
            return definition["server"] is String && definition["tool"] is String
                && (definition["input"] == nil || definition["input"] is [String: Any])
        case "prompt", "agent":
            return true
        default:
            return false
        }
    }

    private static func validOptionalString(_ value: Any?) -> Bool {
        value == nil || value is String || value is NSNull
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isManaged(_ command: String) -> Bool {
        let suffix = " " + argument
        guard command.hasPrefix("exec '/"), command.hasSuffix(suffix) else { return false }
        let quoted = String(command.dropFirst("exec ".count).dropLast(suffix.count))
        guard quoted.last == "'" else { return false }
        let decoded = quoted.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
        return URL(fileURLWithPath: decoded).lastPathComponent == "AgentHoldHook" && shellQuote(decoded) == quoted
    }

    private static func read(_ file: URL) throws -> Data? {
        do {
            let metadata = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink == false,
                  let size = metadata.fileSize, size <= maximumConfigurationBytes else {
                throw ConfigurationError.invalidStructure
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumConfigurationBytes + 1) ?? Data()
            guard data.count <= maximumConfigurationBytes else { throw ConfigurationError.invalidStructure }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private enum ConfigurationError: LocalizedError {
        case hookMissing
        case invalidStructure
        case concurrentChange

        var errorDescription: String? {
            switch self {
            case .hookMissing:
                "找不到 AgentHoldHook。请使用打包后的 AgentHold。"
            case .invalidStructure:
                "无法识别现有 hooks.json 的结构，已保留原文件。"
            case .concurrentChange:
                "hooks.json 同时被其他程序修改，请核对后重试。"
            }
        }
    }
}
