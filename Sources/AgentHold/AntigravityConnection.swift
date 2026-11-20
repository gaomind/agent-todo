import Combine
import CoreFoundation
import Foundation

@MainActor
final class AntigravityConnection: ObservableObject {
    enum Phase {
        case idle
        case needsApproval(AntigravityHookConfiguration)
        case ready
        case missingCLI
        case failed(String)
    }

    struct Settings {
        let home: URL
        let hook: URL?
        let environment: [String: String]

        static func live() -> Self {
            Self(
                home: FileManager.default.homeDirectoryForCurrentUser,
                hook: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentHoldHook"),
                environment: ProcessInfo.processInfo.environment
            )
        }

        var probeConfiguration: URL { home.appendingPathComponent(".gemini/config/hooks.json") }

        func configuration() throws -> AntigravityHookConfiguration {
            guard let hook, ClaudeHookConfiguration.isExecutable(hook) else {
                throw AntigravityHookConfiguration.Failure.missingHook
            }
            let directory = probeConfiguration.deletingLastPathComponent().resolvingSymlinksInPath()
            return AntigravityHookConfiguration(file: directory.appendingPathComponent("hooks.json"), executable: hook)
        }

        func findCLI() -> URL? {
            ProviderCLI.find("agy", home: home, environment: environment)
        }
    }

    @Published private(set) var phase = Phase.idle
    private let settings: Settings
    private var checkedCLI: URL?
    private var reviewedData: Data?

    var cliURL: URL? {
        guard case .ready = phase else { return nil }
        return checkedCLI
    }

    var probeConfiguration: URL? {
        guard case .ready = phase else { return nil }
        return settings.probeConfiguration
    }

    init(settings: Settings = .live()) {
        self.settings = settings
    }

    func check() {
        update {
            checkedCLI = settings.findCLI()
            guard checkedCLI != nil else { return .missingCLI }
            let configuration = try settings.configuration()
            reviewedData = try HookSettingsFile.read(configuration.file)?.data
            return try configuration.replacement(for: reviewedData) == nil
                ? .ready : .needsApproval(configuration)
        }
    }

    func approve() {
        guard case .needsApproval(let configuration) = phase else { return }
        update {
            guard let cli = settings.findCLI() else { return .missingCLI }
            guard configuration == (try settings.configuration()) else {
                throw HookSettingsFile.Failure.concurrentChange
            }
            try HookSettingsFile.update(configuration.file) { original in
                guard original == reviewedData else { throw HookSettingsFile.Failure.concurrentChange }
                return try configuration.replacement(for: original)
            }
            checkedCLI = cli
            return .ready
        }
    }

    func reset() {
        reviewedData = nil
        phase = .idle
    }

    private func update(_ action: () throws -> Phase) {
        do {
            phase = try action()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct AntigravityHookConfiguration: Equatable {
    static let name = "agent-todo"
    static let installCommand = "curl -fsSL https://antigravity.google/cli/install.sh | bash"
    let file: URL
    let executable: URL

    var command: String {
        "exec \(CodexHookConfiguration.shellQuote(executable.path)) --agent-hold-stop-hook --provider antigravity"
    }

    private var definition: [String: Any] {
        ["Stop": [["type": "command", "command": command, "timeout": 10]]]
    }

    func replacement(for original: Data?) throws -> Data? {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let encoded = try JSONSerialization.data(withJSONObject: [Self.name: definition], options: options)
        guard let original else { return encoded + Data([0x0A]) }
        guard !original.contains(0), String(data: original, encoding: .utf8) != nil,
              let root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
            throw Failure.invalidSettings
        }
        if let existing = root[Self.name] {
            guard var hook = existing as? [String: Any] else { throw Failure.conflictingHook }
            if let enabled = hook.removeValue(forKey: "enabled") {
                guard let boolean = enabled as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
                    throw Failure.conflictingHook
                }
                guard boolean.boolValue else { throw Failure.disabled }
            }
            guard NSDictionary(dictionary: hook) == NSDictionary(dictionary: definition) else {
                throw Failure.conflictingHook
            }
            return nil
        }

        // Insert the new definition without re-encoding the shared entries.
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard let end = original.lastIndex(where: { !whitespace.contains($0) }), original[end] == 0x7D,
              let previous = original[..<end].lastIndex(where: { !whitespace.contains($0) }),
              original[previous] != 0x2C else {
            throw Failure.invalidSettings
        }
        var result = Data(original[...previous])
        if !root.isEmpty { result.append(0x2C) }
        result.append(contentsOf: encoded.dropFirst().dropLast())
        result.append(contentsOf: original[(previous + 1)...])
        return result
    }

    enum Failure: LocalizedError {
        case missingHook, invalidSettings, disabled, conflictingHook

        var errorDescription: String? {
            switch self {
            case .missingHook: "找不到采集助手。请从完整的 Agent Todo 应用打开设置。"
            case .invalidSettings: "~/.gemini/config/hooks.json 必须是有效的 JSON 对象。请检查文件格式后重试。"
            case .disabled: "配置中的 agent-todo 条目已停用。请检查该条目后重试。"
            case .conflictingHook: "配置中已有不同的 agent-todo 条目。请检查该条目和采集助手路径后重试。"
            }
        }
    }
}
