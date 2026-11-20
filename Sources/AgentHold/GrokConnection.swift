import Combine
import Darwin
import Foundation

@MainActor
final class GrokConnection: ObservableObject {
    enum Phase {
        case idle
        case checking
        case needsInstallation(GrokHookConfiguration)
        case ready
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    private var operation: Task<Void, Never>?
    private let home: URL
    private let hook: URL?

    init() {
        home = FileManager.default.homeDirectoryForCurrentUser
        hook = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentHoldHook")
    }

    func check() {
        start(install: false)
    }

    func install(_ configuration: GrokHookConfiguration) {
        start(install: true, approved: configuration)
    }

    func cancel() {
        operation?.cancel()
        phase = .idle
    }

    private func start(install: Bool, approved: GrokHookConfiguration? = nil) {
        guard operation == nil else { return }
        phase = .checking
        operation = Task {
            defer { operation = nil }
            do {
                let cli = try findCLI()
                guard let hook, FileManager.default.isExecutableFile(atPath: hook.path) else {
                    throw GrokConnectionFailure.missingHook
                }
                let configuration = GrokHookConfiguration(
                    grokHome: try Self.grokHome(userHome: home, environment: ProcessInfo.processInfo.environment),
                    executable: hook
                )
                if install, configuration != approved { throw GrokConnectionFailure.changed }
                let current = try await GrokInspection.run(cli: cli, home: home, configuration: configuration)
                try Task.checkCancellation()
                if current.contains(configuration) {
                    phase = .ready
                } else if install {
                    try configuration.install()
                    let verified = try await GrokInspection.run(cli: cli, home: home, configuration: configuration)
                    try Task.checkCancellation()
                    guard verified.contains(configuration) else { throw GrokConnectionFailure.notDiscovered }
                    phase = .ready
                } else {
                    if configuration.fileExists {
                        throw GrokConnectionFailure.existingConfiguration(configuration.file.path)
                    }
                    phase = .needsInstallation(configuration)
                }
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func grokHome(userHome: URL, environment: [String: String]) throws -> URL {
        guard let path = environment["GROK_HOME"], !path.isEmpty else {
            return userHome.appendingPathComponent(".grok", isDirectory: true)
        }
        guard path.hasPrefix("/") else { throw GrokConnectionFailure.relativeHome }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func findCLI() throws -> URL {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("grok") }
        let candidates = [
            home.appendingPathComponent(".grok/bin/grok"),
            home.appendingPathComponent(".local/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok"),
        ] + pathCandidates
        for candidate in candidates {
            let executable = candidate.resolvingSymlinksInPath().standardizedFileURL
            let metadata = try? executable.resourceValues(forKeys: [.isRegularFileKey])
            if metadata?.isRegularFile == true, FileManager.default.isExecutableFile(atPath: executable.path) {
                return executable
            }
        }
        throw GrokConnectionFailure.missingCLI
    }
}

struct GrokHookConfiguration: Equatable {
    let grokHome: URL
    let executable: URL

    var directory: URL { grokHome.appendingPathComponent("hooks", isDirectory: true) }
    var file: URL { directory.appendingPathComponent("agent-hold.json") }
    var fileExists: Bool {
        var metadata = stat()
        return lstat(file.path, &metadata) == 0
    }
    var command: String {
        let quoted = executable.path.replacingOccurrences(of: "'", with: "'\\''")
        return "exec '\(quoted)' --agent-hold-stop-hook --provider grok"
    }

    func install() throws {
        let configuration: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": command, "timeout": 5]]]]],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])

        // Write a temporary file outside the scanned format and install it exclusively so that
        // Grok cannot see a partial JSON document and a concurrent edit is never overwritten.
        let temporary = directory.appendingPathComponent(".agent-hold-\(UUID().uuidString).tmp")
        try bytes.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if link(temporary.path, file.path) != 0 {
            if errno == EEXIST { throw GrokConnectionFailure.existingConfiguration(file.path) }
            throw GrokConnectionFailure.write
        }
    }
}

struct GrokInspection: Decodable {
    struct Hook: Decodable {
        struct Source: Decodable {
            let type: String
            let path: String?
        }

        let event: String
        let hookType: String
        let target: String
        let source: Source
        let matcher: String?
    }

    let grokVersion: String
    let hooks: [Hook]

    func contains(_ configuration: GrokHookConfiguration) -> Bool {
        hooks.filter { hook in
            guard hook.event == "stop", hook.hookType == "command", hook.target == configuration.command,
                  hook.source.type == "user", hook.matcher == nil, let path = hook.source.path,
                  path.hasPrefix("/") else { return false }
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            let directory = configuration.directory.resolvingSymlinksInPath().standardizedFileURL.path
            return source == directory
        }.count == 1
    }

    static func run(cli: URL, home: URL, configuration: GrokHookConfiguration,
                    timeout: Duration = .seconds(10)) async throws -> Self {
        let pipe = Pipe()
        let stdout = pipe.fileHandleForReading
        let flags = fcntl(stdout.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(stdout.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw GrokConnectionFailure.launch
        }
        defer {
            try? stdout.close()
            try? pipe.fileHandleForWriting.close()
        }

        let process = Process()
        process.executableURL = cli
        process.currentDirectoryURL = home
        process.arguments = ["--cwd", home.path, "inspect", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["GROK_HOME"] = configuration.grokHome.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GrokConnectionFailure.launch
        }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        func drain() throws {
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(stdout.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { return }
                if count < 0 && errno == EINTR { continue }
                guard count > 0, data.count + count <= 2 * 1024 * 1024 else {
                    throw GrokConnectionFailure.invalidOutput
                }
                data.append(contentsOf: buffer.prefix(count))
            }
        }

        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw GrokConnectionFailure.timeout }
                try drain()
                try await Task.sleep(for: .milliseconds(30))
            }
            try drain()
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw error
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let result = try? JSONDecoder().decode(Self.self, from: data),
              !result.grokVersion.isEmpty else { throw GrokConnectionFailure.invalidOutput }
        return result
    }
}

enum GrokConnectionFailure: LocalizedError, Equatable {
    case missingCLI, missingHook, changed, launch, timeout, invalidOutput, write, notDiscovered, relativeHome
    case existingConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI: "找不到本机的 Grok Build CLI。请安装 xAI 的 Grok Build CLI 后重试。"
        case .missingHook: "找不到可执行的 AgentHoldHook。请打开完整的 Agent Todo 应用。"
        case .changed: "Stop Hook 配置在确认期间发生变化。请重新检查。"
        case .launch: "无法启动 Grok Build CLI 的配置检查。"
        case .timeout: "等待 Grok Build CLI 返回配置时超时。"
        case .invalidOutput: "Grok CLI 未返回可识别的 Grok Build 配置。请检查版本和当前配置。"
        case .existingConfiguration(let path):
            "Grok 未发现与当前应用路径匹配的 Stop Hook。请检查 \(path)。若该文件是旧版应用生成的，请将它移出 hooks 目录，再重新启用采集。"
        case .relativeHome: "当前 GROK_HOME 是相对路径。请设置为绝对路径后重新打开 Agent Todo。"
        case .write: "无法写入 Grok 的个人 Stop Hook。请检查配置目录权限。"
        case .notDiscovered: "已写入 Stop Hook 配置，但 Grok 未确认加载。请检查 Grok 的有效配置。"
        }
    }
}
