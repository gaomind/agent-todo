import Combine
import Foundation

@MainActor
final class ClaudeConnection: ObservableObject {
    enum Phase {
        case idle
        case needsApproval(Review)
        case ready(URL)
        case failed(String)
    }

    struct Review {
        let command: String
        let configuration: URL
        fileprivate let executable: URL
    }

    struct Settings {
        let home: URL
        let configurationDirectory: URL
        let hook: URL?
        var cli: URL? = nil
        var hasRelativeConfigurationDirectory = false

        static func live() -> Self {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            let directory = override.flatMap { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
            } ?? home.appendingPathComponent(".claude")
            return Self(
                home: home, configurationDirectory: directory,
                hook: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentHoldHook"),
                hasRelativeConfigurationDirectory: override.map { !$0.isEmpty && !$0.hasPrefix("/") } ?? false
            )
        }

        func findCLI() throws {
            let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("claude") }
            let candidates = cli.map { [$0] } ?? [
                home.appendingPathComponent(".local/bin/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
            ] + pathCandidates
            guard candidates.contains(where: ClaudeHookConfiguration.isExecutable) else {
                throw ClaudeHookConfiguration.Failure.missingCLI
            }
        }

        var configuration: URL {
            configurationDirectory.resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent("settings.json")
        }
    }

    @Published private(set) var phase = Phase.idle
    private let settings: Settings

    init(settings: Settings = .live()) {
        self.settings = settings
    }

    func prepare() {
        update {
            if settings.hasRelativeConfigurationDirectory {
                throw ClaudeHookConfiguration.Failure.relativeConfigurationDirectory
            }
            try settings.findCLI()
            guard let hook = settings.hook, ClaudeHookConfiguration.isExecutable(hook) else {
                throw ClaudeHookConfiguration.Failure.missingHook
            }
            let review = Review(
                command: ClaudeHookConfiguration.command(for: hook),
                configuration: settings.configuration,
                executable: hook
            )
            let installed = try ClaudeHookConfiguration.isInstalled(at: review.configuration, executable: hook)
            return installed ? .ready(review.configuration) : .needsApproval(review)
        }
    }

    func approve() {
        guard case let .needsApproval(review) = phase else { return }
        update {
            guard review.configuration == settings.configuration else {
                throw ClaudeHookConfiguration.Failure.concurrentChange
            }
            try ClaudeHookConfiguration.install(at: review.configuration, executable: review.executable)
            return .ready(review.configuration)
        }
    }

    func reset() {
        phase = .idle
    }

    private func update(_ operation: () throws -> Phase) {
        do {
            phase = try operation()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

enum ClaudeHookConfiguration {
    private static let arguments = "--agent-hold-stop-hook --provider claude"
    private static let maximumConfigurationBytes = 1024 * 1024
    private static let timeout = 5

    static func command(for executable: URL) -> String {
        "exec \(CodexHookConfiguration.shellQuote(executable.path)) \(arguments)"
    }

    static func isExecutable(_ url: URL) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        let resolved = url.resolvingSymlinksInPath()
        let metadata = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        return metadata?.isRegularFile == true && FileManager.default.isExecutableFile(atPath: resolved.path)
    }

    static func isInstalled(at file: URL, executable: URL) throws -> Bool {
        try translateFileErrors {
            try replacement(for: HookSettingsFile.read(file)?.data, command: command(for: executable)) == nil
        }
    }

    static func install(at file: URL, executable: URL) throws {
        guard isExecutable(executable) else { throw Failure.missingHook }
        try translateFileErrors {
            try HookSettingsFile.update(file) { try replacement(for: $0, command: command(for: executable)) }
        }
    }

    private static func translateFileErrors<T>(_ action: () throws -> T) throws -> T {
        do {
            return try action()
        } catch let error as HookSettingsFile.Failure {
            switch error {
            case .concurrentChange: throw Failure.concurrentChange
            case .invalidSettings: throw Failure.invalidSettings
            case .readFailed: throw Failure.readFailed
            case .writeFailed: throw Failure.writeFailed
            }
        }
    }

    private static func replacement(for original: Data?, command: String) throws -> Data? {
        var root: [String: Any] = [:]
        if let original {
            guard let dictionary = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
                throw Failure.invalidSettings
            }
            root = dictionary
        }
        if root["disableAllHooks"] as? Bool == true { throw Failure.disabled }

        var events: [String: Any] = [:]
        if let value = root["hooks"] {
            guard let dictionary = value as? [String: Any] else { throw Failure.invalidSettings }
            events = dictionary
        }
        var stopGroups: [[String: Any]] = []
        if let value = events["Stop"] {
            guard let groups = value as? [[String: Any]] else { throw Failure.invalidSettings }
            stopGroups = groups
        }

        let handler: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
        var ownedGroup: Int?
        for (index, group) in stopGroups.enumerated() {
            guard let handlers = group["hooks"] as? [[String: Any]] else { throw Failure.invalidSettings }
            for hook in handlers {
                guard let existing = hook["command"] as? String,
                      existing == command || isManaged(existing) else { continue }
                guard ownedGroup == nil, handlers.count == 1, Set(group.keys) == ["hooks"],
                      Set(hook.keys) == Set(handler.keys),
                      hook["type"] as? String == "command",
                      hook["timeout"] as? Int == timeout else { throw Failure.conflictingHook }
                ownedGroup = index
            }
        }
        if let ownedGroup {
            let hooks = stopGroups[ownedGroup]["hooks"] as? [[String: Any]]
            if hooks?.first?["command"] as? String == command { return nil }
            stopGroups[ownedGroup] = ["hooks": [handler]]
        } else {
            stopGroups.append(["hooks": [handler]])
        }
        events["Stop"] = stopGroups
        root["hooks"] = events
        var data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        guard data.count <= maximumConfigurationBytes else { throw Failure.invalidSettings }
        return data
    }

    private static func isManaged(_ command: String) -> Bool {
        let prefix = "exec "
        let suffix = " " + arguments
        guard command.hasPrefix(prefix + "'/"), command.hasSuffix("'" + suffix) else { return false }
        let quoted = String(command.dropFirst(prefix.count).dropLast(suffix.count))
        let path = quoted.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
        return URL(fileURLWithPath: path).lastPathComponent == "AgentHoldHook"
            && CodexHookConfiguration.shellQuote(path) == quoted
    }

    enum Failure: LocalizedError {
        case missingCLI, missingHook, invalidSettings, disabled, conflictingHook
        case relativeConfigurationDirectory, concurrentChange, readFailed, writeFailed

        var errorDescription: String? {
            switch self {
            case .missingCLI: "找不到本机可执行的 Claude Code CLI。请检查 Claude Code 的安装。"
            case .missingHook: "找不到 AgentHoldHook。请打开完整的 Agent 待办应用。"
            case .invalidSettings: "Claude Code 的 settings.json 格式无效、超过 1 MiB 或不是常规文件。"
            case .disabled: "Claude Code 用户配置中的 disableAllHooks 已开启。请检查配置后重试。"
            case .conflictingHook: "Claude Code 配置中已有自定义或重复的 Agent 待办 Stop Hook。请检查相关条目后重试。"
            case .relativeConfigurationDirectory: "CLAUDE_CONFIG_DIR 是相对路径。请用绝对路径指定 Claude Code 配置目录。"
            case .concurrentChange: "Claude Code 配置正在被其他操作修改。请重新检查后重试。"
            case .readFailed: "无法读取 Claude Code 用户配置。请检查文件权限。"
            case .writeFailed: "无法保存 Claude Code 用户配置。请检查文件权限。"
            }
        }
    }
}
