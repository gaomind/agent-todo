import Combine
import Darwin
import Foundation

@MainActor
final class CodexConnection: ObservableObject {
    enum Phase {
        case idle
        case checking
        case needsApproval(Review)
        case ready(URL)
        case failed(String)
    }

    struct Review: Equatable {
        let command: String
        let sourcePath: String
        let workingDirectory: String
        fileprivate let cli: URL
        fileprivate let key: String
        fileprivate let hash: String
    }

    @Published private(set) var phase = Phase.idle
    private var operation: Task<Void, Never>?
    private let settings: Settings

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        settings = Settings(
            home: home,
            codexHome: home.appendingPathComponent(".codex"),
            hook: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentHoldHook")
        )
    }

    init(settings: Settings) {
        self.settings = settings
    }

    deinit {
        operation?.cancel()
    }

    func prepare() {
        start { settings in
            let cli = try settings.findCLI()
            guard let hook = settings.hook else { throw Failure.missingHook }
            try CodexHookConfiguration.install(at: settings.hookConfiguration, executable: hook)

            let server = try AppServer(cli: cli, settings: settings)
            defer { server.close() }
            try await server.initialize()
            let (review, status) = try await server.inspect(command: CodexHookConfiguration.command(for: hook))
            await server.finish()
            return status == "trusted" ? .ready(cli) : .needsApproval(review)
        }
    }

    func approve() {
        guard case let .needsApproval(approved) = phase else { return }
        start { settings in
            let server = try AppServer(cli: approved.cli, settings: settings)
            defer { server.close() }
            try await server.initialize()
            let (current, status) = try await server.inspect(command: approved.command)
            guard current == approved else { throw Failure.changed }
            if status != "trusted" {
                try await server.trust(approved)
                let (result, status) = try await server.inspect(command: approved.command)
                guard result == approved, status == "trusted" else { throw Failure.trustUnverified }
            }
            await server.finish()
            return .ready(approved.cli)
        }
    }

    func reset() {
        phase = .idle
        operation?.cancel()
    }

    func resetAndWait() async {
        let running = operation
        reset()
        await running?.value
    }

    private func start(_ run: @escaping @MainActor (Settings) async throws -> Phase) {
        guard operation == nil else { return }
        phase = .checking
        let settings = self.settings
        operation = Task { [weak self] in
            defer { self?.operation = nil }
            do {
                try Task.checkCancellation()
                let result = try await run(settings)
                try Task.checkCancellation()
                self?.phase = result
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    struct Settings {
        let home: URL
        let codexHome: URL
        let hook: URL?
        var cli: URL? = nil
        var timeout: Duration = .seconds(10)

        var cwd: URL { home.resolvingSymlinksInPath().standardizedFileURL }
        var hookConfiguration: URL { codexHome.appendingPathComponent("hooks.json") }

        func findCLI() throws -> URL {
            let candidates = cli.map { [$0] } ?? [
                home.appendingPathComponent(".local/bin/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            ]
            for candidate in candidates {
                let executable = candidate.resolvingSymlinksInPath().standardizedFileURL
                let metadata = try? executable.resourceValues(forKeys: [.isRegularFileKey])
                if metadata?.isRegularFile == true, FileManager.default.isExecutableFile(atPath: executable.path) {
                    return executable
                }
            }
            throw Failure.missingCLI
        }
    }

    private enum Stage: String {
        case initialize = "启动和握手"
        case inspect = "查询 Stop Hook"
        case trust = "保存 Hook 信任"
    }

    private enum Failure: LocalizedError {
        case missingHook, missingCLI, launch, timeout(Stage), closed, protocolMismatch, wrongHome
        case missingHookMetadata, disabled, changed, trustUnverified, writeRejected

        var errorDescription: String? {
            switch self {
            case .missingHook: "找不到 AgentHoldHook。请打开完整的 Agent Todo 应用。"
            case .missingCLI: "找不到本机可执行的 Codex CLI。请安装或更新 Codex CLI 后重试。"
            case .launch: "无法启动本机 Codex CLI 的 app-server。请检查 Codex 安装后重试。"
            case .timeout(let stage): "本机 Codex CLI 在\(stage.rawValue)时超时。请重试。"
            case .closed: "本机 Codex CLI 提前退出。请检查 Codex 的版本和配置。"
            case .protocolMismatch: "本机 Codex CLI 未提供可识别的 Hook 管理接口。请更新 Codex CLI 后重试。"
            case .wrongHome: "Codex CLI 返回的配置目录与当前应用配置目标不一致。"
            case .missingHookMetadata:
                "Codex CLI 未发现唯一匹配的 Agent Todo Stop Hook。请检查默认 ~/.codex 的 Hook 功能和有效配置。"
            case .disabled: "Codex CLI 发现 Agent Todo Stop Hook，但它已停用。请先在 Codex 中启用该 Hook。"
            case .changed: "Hook 在确认期间发生变化。请重新检查并确认当前命令。"
            case .trustUnverified: "已请求保存信任，Codex CLI 未确认该 Hook 已启用并信任。请重新检查。"
            case .writeRejected: "Codex CLI 拒绝写入该 Hook 的信任设置。请检查配置权限或管理策略。"
            }
        }
    }

    @MainActor
    private final class AppServer {
        private struct Hook: Decodable {
            let source: String
            let sourcePath: String
            let eventName: String
            let handlerType: String
            let command: String?
            let enabled: Bool
            let isManaged: Bool
            let trustStatus: String
            let key: String
            let currentHash: String
        }

        private struct HookList: Decodable {
            struct Entry: Decodable {
                let cwd: String
                let hooks: [Hook]
            }
            let data: [Entry]
        }

        private let cli: URL
        private let settings: Settings
        private let scratch: URL
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let clock = ContinuousClock()
        private let deadline: ContinuousClock.Instant
        private var nextID = 0
        private var buffer = Data()
        private var receivedBytes = 0
        private let maximumBytes = 2 * 1024 * 1024

        init(cli: URL, settings: Settings) throws {
            self.cli = cli
            self.settings = settings
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHoldCodex-\(UUID().uuidString)")
            deadline = clock.now + settings.timeout
            do {
                try FileManager.default.createDirectory(
                    at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = .withoutEscapingSlashes
                let scratchPath = String(decoding: try encoder.encode(scratch.path), as: UTF8.self)
                process.executableURL = cli
                process.currentDirectoryURL = settings.cwd
                process.environment = [
                    "HOME": settings.home.path,
                    "CODEX_HOME": settings.codexHome.path,
                    "PATH": [cli.deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
                    "TMPDIR": scratch.path,
                ]
                process.arguments = [
                    "app-server", "--stdio",
                    "-c", "cli_auth_credentials_store=\"ephemeral\"",
                    "-c", "analytics.enabled=false",
                    // Reuse Codex's normal state database. A new SQLite home causes Codex
                    // to index the real session store before reading its first RPC.
                    "-c", "log_dir=\(scratchPath)",
                ]
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                let writeFD = input.fileHandleForWriting.fileDescriptor
                let readFD = output.fileHandleForReading.fileDescriptor
                guard fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1,
                      fcntl(writeFD, F_SETFL, O_NONBLOCK) != -1,
                      fcntl(readFD, F_SETFL, O_NONBLOCK) != -1 else {
                    throw Failure.launch
                }
                try Task.checkCancellation()
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: scratch)
                if error is CancellationError { throw error }
                throw Failure.launch
            }
        }

        func close() {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: scratch)
        }

        func finish() async {
            try? input.fileHandleForWriting.close()
            let shutdownDeadline = clock.now + .milliseconds(250)
            while process.isRunning && clock.now < shutdownDeadline && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(15))
            }
        }

        func initialize() async throws {
            let result = try await request("initialize", stage: .initialize, params: [
                "clientInfo": ["name": "agent-hold", "version": "1.0"],
                "capabilities": NSNull(),
            ])
            guard let home = result["codexHome"] as? String else { throw Failure.protocolMismatch }
            guard matchesPath(home, settings.codexHome) else { throw Failure.wrongHome }
            try await send(["method": "initialized", "params": [:]], stage: .initialize)
        }

        func inspect(command: String) async throws -> (Review, String) {
            let result = try await request("hooks/list", stage: .inspect, params: ["cwds": [settings.cwd.path]])
            let list: HookList
            do {
                list = try JSONDecoder().decode(HookList.self, from: JSONSerialization.data(withJSONObject: result))
            } catch {
                throw Failure.protocolMismatch
            }
            guard list.data.count == 1, let entry = list.data.first,
                  matchesPath(entry.cwd, settings.cwd) else { throw Failure.protocolMismatch }
            let matching = entry.hooks.filter { hook in
                hook.source == "user" && hook.eventName == "stop" && hook.handlerType == "command"
                    && !hook.isManaged && hook.command == command
                    && matchesPath(hook.sourcePath, settings.hookConfiguration)
            }
            guard matching.count == 1, let hook = matching.first else { throw Failure.missingHookMetadata }
            guard hook.enabled else { throw Failure.disabled }
            guard !hook.key.isEmpty, !hook.currentHash.isEmpty,
                  ["trusted", "untrusted", "modified"].contains(hook.trustStatus) else {
                throw Failure.protocolMismatch
            }
            return (Review(command: command, sourcePath: hook.sourcePath, workingDirectory: entry.cwd,
                           cli: cli, key: hook.key, hash: hook.currentHash), hook.trustStatus)
        }

        func trust(_ review: Review) async throws {
            let result = try await request("config/batchWrite", stage: .trust, params: [
                "edits": [[
                    "keyPath": "hooks.state",
                    "value": [review.key: ["trusted_hash": review.hash]],
                    "mergeStrategy": "upsert",
                ]],
                "reloadUserConfig": true,
            ])
            let config = settings.codexHome.appendingPathComponent("config.toml")
            guard ["ok", "okOverridden"].contains(result["status"] as? String ?? ""),
                  let path = result["filePath"] as? String,
                  matchesPath(path, config) else { throw Failure.trustUnverified }
        }

        private func matchesPath(_ path: String, _ target: URL) -> Bool {
            path.hasPrefix("/") && URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == target.resolvingSymlinksInPath().path
        }

        private func request(_ method: String, stage: Stage, params: [String: Any]) async throws -> [String: Any] {
            nextID += 1
            let id = nextID
            try await send(["id": id, "method": method, "params": params], stage: stage)
            while true {
                try checkDeadline(stage)
                if let lineEnd = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<lineEnd])
                    buffer.removeSubrange(...lineEnd)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw Failure.protocolMismatch
                    }
                    guard message["id"] as? Int == id, message["method"] == nil else { continue }
                    if let error = message["error"] as? [String: Any] {
                        if method == "config/batchWrite", error["code"] as? Int != -32601 {
                            throw Failure.writeRejected
                        }
                        throw Failure.protocolMismatch
                    }
                    guard let result = message["result"] as? [String: Any] else { throw Failure.protocolMismatch }
                    return result
                }
                try await read()
            }
        }

        private func checkDeadline(_ stage: Stage) throws {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure.timeout(stage) }
        }

        private func read() async throws {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                receivedBytes += count
                guard receivedBytes <= maximumBytes else { throw Failure.protocolMismatch }
                buffer.append(contentsOf: bytes.prefix(count))
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                try await Task.sleep(for: .milliseconds(15))
            } else {
                throw Failure.closed
            }
        }

        private func send(_ message: [String: Any], stage: Stage) async throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            var offset = 0
            while offset < data.count {
                try checkDeadline(stage)
                let count = data.withUnsafeBytes { bytes in
                    Darwin.write(input.fileHandleForWriting.fileDescriptor,
                                 bytes.baseAddress?.advanced(by: offset), data.count - offset)
                }
                if count > 0 {
                    offset += count
                } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                    try await Task.sleep(for: .milliseconds(15))
                } else {
                    throw Failure.closed
                }
            }
        }
    }
}
