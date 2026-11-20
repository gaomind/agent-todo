import Combine
import CoreFoundation
import Foundation

@MainActor
final class GeminiConnection: ObservableObject {
    enum Phase {
        case idle
        case needsApproval(GeminiHookConfiguration)
        case ready
        case manual(GeminiHookConfiguration)
        case failed(String)
    }

    struct Settings {
        let home: URL
        let hook: URL?
        let environment: [String: String]
        var cli: URL? = nil

        static func live() -> Self {
            Self(
                home: FileManager.default.homeDirectoryForCurrentUser,
                hook: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentHoldHook"),
                environment: ProcessInfo.processInfo.environment
            )
        }

        func configuration() throws -> GeminiHookConfiguration {
            guard let hook, ClaudeHookConfiguration.isExecutable(hook) else {
                throw GeminiHookConfiguration.Failure.missingHook
            }
            let home = try GeminiConnection.geminiHome(userHome: home, environment: environment)
            return GeminiHookConfiguration(
                file: home.appendingPathComponent(".gemini", isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("settings.json"),
                executable: hook
            )
        }

        func findCLI() throws {
            let pathCandidates = (environment["PATH"] ?? "").split(separator: ":")
                .filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("gemini") }
            let prefix = environment["npm_config_prefix"] ?? environment["NPM_CONFIG_PREFIX"]
            let prefixCandidate = prefix.flatMap { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path).appendingPathComponent("bin/gemini") : nil
            }
            let candidates = pathCandidates + [
                prefixCandidate,
                home.appendingPathComponent(".local/bin/gemini"),
                home.appendingPathComponent(".npm-global/bin/gemini"),
                home.appendingPathComponent(".volta/bin/gemini"),
                home.appendingPathComponent(".asdf/shims/gemini"),
                URL(fileURLWithPath: "/opt/homebrew/bin/gemini"),
                URL(fileURLWithPath: "/usr/local/bin/gemini"),
            ].compactMap { $0 }
            if let cli {
                guard ClaudeHookConfiguration.isExecutable(cli) else { throw GeminiHookConfiguration.Failure.missingCLI }
                return
            }
            if candidates.contains(where: ClaudeHookConfiguration.isExecutable) { return }

            // Finder-launched apps may lack the Node bin directory managed by nvm.
            let nvm = environment["NVM_DIR"].flatMap { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
            } ?? home.appendingPathComponent(".nvm", isDirectory: true)
            let nodeVersions = nvm.appendingPathComponent("versions/node", isDirectory: true)
            let installed = (try? FileManager.default.contentsOfDirectory(
                at: nodeVersions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            guard installed.contains(where: { version in
                version.lastPathComponent.hasPrefix("v") &&
                    ClaudeHookConfiguration.isExecutable(version.appendingPathComponent("bin/gemini"))
            }) else { throw GeminiHookConfiguration.Failure.missingCLI }
        }
    }

    @Published private(set) var phase = Phase.idle
    private let settings: Settings

    init(settings: Settings = .live()) {
        self.settings = settings
    }

    func check() {
        update {
            try settings.findCLI()
            let configuration = try settings.configuration()
            do {
                return try configuration.isInstalled() ? .ready : .needsApproval(configuration)
            } catch GeminiHookConfiguration.Failure.manualConfiguration {
                return .manual(configuration)
            }
        }
    }

    func approve() {
        guard case .needsApproval(let approved) = phase else { return }
        update {
            guard approved == (try settings.configuration()) else {
                throw HookSettingsFile.Failure.concurrentChange
            }
            do {
                try approved.install()
                return .ready
            } catch GeminiHookConfiguration.Failure.manualConfiguration {
                return .manual(approved)
            }
        }
    }

    func reset() { phase = .idle }

    private func update(_ action: () throws -> Phase) {
        do {
            phase = try action()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated static func geminiHome(userHome: URL, environment: [String: String]) throws -> URL {
        guard let path = environment["GEMINI_CLI_HOME"], !path.isEmpty else { return userHome }
        guard path.hasPrefix("/") else { throw GeminiHookConfiguration.Failure.relativeHome }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

struct GeminiHookConfiguration: Equatable {
    static let name = "agent-hold"
    private static let arguments = " --agent-hold-stop-hook --provider gemini"
    private static let timeout = 5000
    let file: URL
    let executable: URL

    var command: String {
        "exec \(CodexHookConfiguration.shellQuote(executable.path))\(Self.arguments)"
    }

    var snippet: String {
        let root = ["hooks": ["AfterAgent": [["hooks": [handler]]]]]
        let data = try? JSONSerialization.data(withJSONObject: root, options: Self.jsonOptions)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func isInstalled() throws -> Bool {
        try replacement(for: HookSettingsFile.read(file)?.data) == nil
    }

    func install() throws {
        guard ClaudeHookConfiguration.isExecutable(executable) else { throw Failure.missingHook }
        try HookSettingsFile.update(file) { try replacement(for: $0) }
    }

    private var handler: [String: Any] {
        ["name": Self.name, "type": "command", "command": command, "timeout": Self.timeout]
    }

    private static let jsonOptions: JSONSerialization.WritingOptions = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]

    private func replacement(for original: Data?) throws -> Data? {
        var root: [String: Any] = [:]
        var hasComments = false
        if let original {
            let parsed = try Self.parse(original)
            root = parsed.root
            hasComments = parsed.hasComments
        }

        let options: [String: Any] = try Self.setting(root["hooksConfig"], default: [:])
        if let enabled = options["enabled"] {
            guard let number = enabled as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw Failure.invalidSettings
            }
            if !number.boolValue { throw Failure.disabled }
        }
        let disabled: [String] = try Self.setting(options["disabled"], default: [])
        guard !disabled.contains(Self.name), !disabled.contains(command) else { throw Failure.disabled }

        var events: [String: Any] = try Self.setting(root["hooks"], default: [:])
        var afterAgent: [[String: Any]] = try Self.setting(events["AfterAgent"], default: [])
        var managedIndex: Int?
        for (index, group) in afterAgent.enumerated() {
            guard let handlers = group["hooks"] as? [[String: Any]] else { throw Failure.invalidSettings }
            for entry in handlers {
                let existingCommand = entry["command"] as? String
                guard entry["name"] as? String == Self.name || existingCommand == command ||
                    existingCommand.map(Self.isManaged) == true else { continue }
                guard managedIndex == nil, handlers.count == 1, Set(group.keys) == ["hooks"],
                      Set(entry.keys) == Set(handler.keys), entry["name"] as? String == Self.name,
                      entry["type"] as? String == "command", entry["timeout"] as? Int == Self.timeout,
                      let existingCommand, Self.isManaged(existingCommand) || existingCommand == command else {
                    throw Failure.conflictingHook
                }
                guard !disabled.contains(existingCommand) else { throw Failure.disabled }
                managedIndex = index
            }
        }
        if let managedIndex {
            let entries = afterAgent[managedIndex]["hooks"] as? [[String: Any]]
            if entries?.first?["command"] as? String == command { return nil }
            afterAgent[managedIndex] = ["hooks": [handler]]
        } else {
            afterAgent.append(["hooks": [handler]])
        }

        // Re-serializing with JSONSerialization would remove existing config comments.
        guard !hasComments else { throw Failure.manualConfiguration }
        events["AfterAgent"] = afterAgent
        root["hooks"] = events
        var data = try JSONSerialization.data(withJSONObject: root, options: Self.jsonOptions)
        data.append(0x0A)
        return data
    }

    private static func parse(_ original: Data) throws -> (root: [String: Any], hasComments: Bool) {
        // Gemini strips JavaScript comments before JSON.parse. Keep quoted strings intact and
        // reject trailing commas, which Foundation's JSON parser can accept.
        let bytes = Array(original)
        var stripped = Data()
        stripped.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        var hasComments = false
        var lastToken: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if inString {
                stripped.append(byte)
                if byte == 0x5C, index < bytes.count {
                    stripped.append(bytes[index])
                    index += 1
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            if byte == 0x2F, index < bytes.count {
                if bytes[index] == 0x2F {
                    index += 1
                    while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                        index += 1
                    }
                    stripped.append(0x20)
                    hasComments = true
                    continue
                }
                if bytes[index] == 0x2A {
                    index += 1
                    while index + 1 < bytes.count, bytes[index] != 0x2A || bytes[index + 1] != 0x2F {
                        index += 1
                    }
                    guard index + 1 < bytes.count else { throw Failure.manualConfiguration }
                    index += 2
                    stripped.append(0x20)
                    hasComments = true
                    continue
                }
            }

            if byte == 0x22 { inString = true }
            if (byte == 0x5D || byte == 0x7D), lastToken == 0x2C { throw Failure.manualConfiguration }
            if byte != 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { lastToken = byte }
            stripped.append(byte)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: stripped)) as? [String: Any] else {
            throw Failure.manualConfiguration
        }
        return (root, hasComments)
    }

    private static func setting<T>(_ value: Any?, default fallback: T) throws -> T {
        guard let value else { return fallback }
        guard let result = value as? T else { throw Failure.invalidSettings }
        return result
    }

    private static func isManaged(_ command: String) -> Bool {
        let prefix = "exec "
        guard command.hasPrefix(prefix + "'/"), command.hasSuffix("'" + arguments) else { return false }
        let quoted = String(command.dropFirst(prefix.count).dropLast(arguments.count))
        let path = quoted.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
        return URL(fileURLWithPath: path).lastPathComponent == "AgentHoldHook"
            && CodexHookConfiguration.shellQuote(path) == quoted
    }

    enum Failure: LocalizedError {
        case missingCLI, missingHook, relativeHome, invalidSettings, manualConfiguration, disabled, conflictingHook

        var errorDescription: String? {
            switch self {
            case .missingCLI: "找不到 Gemini CLI。可运行 npm install -g @google/gemini-cli 安装。"
            case .missingHook: "找不到可执行的 AgentHoldHook。请打开完整的 Agent 待办应用。"
            case .relativeHome: "GEMINI_CLI_HOME 是相对路径。请用绝对路径指定 Gemini CLI 主目录。"
            case .invalidSettings: "Gemini CLI 用户配置中的 hooks 或 hooksConfig 结构无效。"
            case .manualConfiguration: "Gemini CLI 当前设置无法按标准 JSON 读取，可能包含注释或语法错误。"
            case .disabled: "Gemini CLI 用户配置禁用了 Hook 或 Agent 待办。请检查 hooksConfig。"
            case .conflictingHook: "Gemini CLI 已有自定义或重复的 Agent 待办 AfterAgent Hook。请检查现有配置。"
            }
        }
    }
}
