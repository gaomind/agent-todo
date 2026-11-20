import AgentHoldCaptureSupport
import Combine
import Darwin
import Foundation

@MainActor
final class CodexLiveProbe: ObservableObject {
    enum State {
        case idle
        case running
        case passed
        case failed(String)
        case cancelled
    }

    @Published private var states: [HoldProvider: State] = [:]
    @Published private(set) var activeProvider: HoldProvider?
    private var task: Task<Void, Never>?
    private var active: Attempt?

    private static let directoryPrefix = "AgentHoldLiveProbe-"
    private let timeout: Duration
    private let receiptTimeout: Duration
    private let codexHome: URL

    init(
        timeout: Duration = .seconds(90),
        receiptTimeout: Duration = .seconds(8),
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    ) {
        self.timeout = timeout
        self.receiptTimeout = receiptTimeout
        self.codexHome = codexHome
    }

    var state: State { state(for: .codex) }

    func state(for provider: HoldProvider) -> State {
        states[provider] ?? .idle
    }

    func start(cli: URL) {
        start(provider: .codex, cli: cli)
    }

    func start(provider: HoldProvider, cli: URL, configuration: URL? = nil) {
        guard task == nil, provider != .unknown else { return }
        activeProvider = provider
        states[provider] = .running
        task = Task {
            defer {
                active = nil
                task = nil
                activeProvider = nil
            }
            do {
                try await run(provider: provider, cli: cli, configuration: configuration)
                states[provider] = .passed
            } catch is CancellationError {
                states[provider] = .cancelled
            } catch {
                states[provider] = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func cancelAndWait() async {
        cancel()
        await task?.value
    }

    func accept(_ reply: CodexReply, conditions: [String]) -> Bool {
        guard let cwd = reply.cwd, cwd.hasPrefix("/") else { return false }
        let directory = Self.canonical(URL(fileURLWithPath: cwd, isDirectory: true))
        let name = directory.lastPathComponent
        guard directory.deletingLastPathComponent() == Self.temporaryDirectory,
              let token = UUID(uuidString: String(name.suffix(36))) else { return false }
        let prefix = String(name.dropLast(36))
        guard prefix == Self.directoryPrefix || Self.isProviderDirectoryPrefix(prefix) else { return false }
        if let active, directory == active.directory, reply.provider == active.provider {
            let containsMarker = reply.message.utf8.count <= HoldDetector.maximumReplyBytes
                && reply.message.localizedCaseInsensitiveContains(token.uuidString)
            active.accept(reply, valid: containsMarker && conditions.contains(active.condition))
        }

        // Keep replies from the private workspace out of ordinary conversations even
        // when the CLI ignored the marker or the receipt arrived after the test.
        return true
    }

    private static func isProviderDirectoryPrefix(_ prefix: String) -> Bool {
        guard prefix.hasPrefix(directoryPrefix), prefix.hasSuffix("-"),
              let provider = HoldProvider(rawValue: String(prefix.dropFirst(directoryPrefix.count).dropLast()))
        else { return false }
        return provider != .unknown
    }

    private static var temporaryDirectory: URL {
        canonical(FileManager.default.temporaryDirectory)
    }

    private static func canonical(_ url: URL) -> URL {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
        // A removed probe directory can no longer be resolved by realpath.
        let path = normalized.hasPrefix("/var/") || normalized.hasPrefix("/tmp/")
            ? "/private" + normalized : normalized
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func run(provider: HoldProvider, cli: URL, configuration: URL?) async throws {
        do {
            try await runProbe(provider: provider, cli: cli, configuration: configuration)
        } catch let failure as Failure {
            throw ProbeFailure(provider: provider, failure: failure)
        }
    }

    private func runProbe(provider: HoldProvider, cli: URL, configuration: URL?) async throws {
        try Task.checkCancellation()
        guard cli.isFileURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw Failure.cliMissing
        }
        let token = UUID().uuidString.lowercased()
        let prefix = provider == .codex ? Self.directoryPrefix : Self.directoryPrefix + provider.rawValue + "-"
        let directory = Self.temporaryDirectory.appendingPathComponent(prefix + token, isDirectory: true)
        let condition = "等待连接测试确认 \(token) 后继续"
        let instructions = "这是连接测试。不要调用任何工具或读取文件。只原样输出下面一行，不要添加其他内容。\n恢复条件：\(condition)。"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.workspace
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try ProviderProbeCommand.make(
            provider: provider, cli: cli, workspace: directory, prompt: instructions,
            environment: ProcessInfo.processInfo.environment, codexHome: codexHome, configuration: configuration
        )
        let attempt = Attempt(provider: provider, directory: directory, condition: condition, command: command)
        active = attempt

        let output = Pipe()
        let errors = Pipe()
        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading
        defer {
            try? stdout.close()
            try? stderr.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }
        for handle in [stdout, stderr] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw Failure.launch
            }
        }

        let process = Process()
        process.executableURL = cli
        process.currentDirectoryURL = attempt.directory
        process.environment = command.environment
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        do {
            try process.run()
        } catch {
            throw Failure.launch
        }
        let pid = process.processIdentifier
        // Foundation may give a Process its own group. Never signal a shared group.
        let ownsProcessGroup = getpgid(pid) == pid
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw Failure.timeout }
                try Self.drain(stdout, stderr, attempt: attempt)
                try await Task.sleep(for: .milliseconds(40))
            }
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure.timeout }
            try Self.drain(stdout, stderr, attempt: attempt)
            attempt.finishOutput()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw attempt.authenticationFailure ? Failure.authentication : Failure.cliExit
            }
            guard let session = attempt.session, !attempt.conflictingSession else { throw Failure.thread }

            let receiptDeadline = min(deadline, clock.now + receiptTimeout)
            repeat {
                try Task.checkCancellation()
                if let valid = attempt.receipts[session] {
                    guard valid else { throw Failure.unexpectedReply }
                    return
                }
                try await Task.sleep(for: .milliseconds(40))
            } while clock.now < receiptDeadline
            if !attempt.receipts.isEmpty { throw Failure.wrongThread }
            throw Failure.noReceipt
        } catch {
            await Self.terminate(process, ownsProcessGroup: ownsProcessGroup)
            throw error
        }
    }

    private static func terminate(_ process: Process, ownsProcessGroup: Bool) async {
        let pid = process.processIdentifier
        let target = ownsProcessGroup ? -pid : pid
        guard process.isRunning || (ownsProcessGroup && kill(target, 0) == 0) else { return }
        kill(target, SIGTERM)
        // The calling task may already be cancelled. Allow the CLI a short
        // grace period before escalating without inheriting that cancellation.
        await Task.detached {
            try? await Task.sleep(for: .milliseconds(400))
        }.value
        if process.isRunning || (ownsProcessGroup && kill(target, 0) == 0) {
            kill(target, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func drain(_ stdout: FileHandle, _ stderr: FileHandle, attempt: Attempt) throws {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for (handle, consume) in [(stdout, attempt.readOutput), (stderr, attempt.readError)] {
            // Bound the work per poll to avoid starving UI and cancellation
            // if the subprocess writes continuously.
            for _ in 0..<4 {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { break }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.output }
                consume(buffer.prefix(count))
            }
        }
    }

    @MainActor
    private final class Attempt {
        let provider: HoldProvider
        let directory: URL
        let condition: String
        private let command: ProviderProbeCommand
        private(set) var session: UUID?
        private(set) var conflictingSession = false
        private(set) var receipts: [UUID: Bool] = [:]

        private var finalOutput: Data?
        private var partialLine = Data()
        private var dropLine = false
        private var errorTail = Data()
        private(set) var authenticationFailure = false

        init(provider: HoldProvider, directory: URL, condition: String, command: ProviderProbeCommand) {
            self.provider = provider
            self.directory = directory
            self.condition = condition
            self.command = command
            session = command.expectedSession
            // Grok's one-shot result is a formatted JSON object spanning several lines.
            finalOutput = provider == .grok ? Data() : nil
        }

        func accept(_ reply: CodexReply, valid: Bool) {
            guard let id = UUID(uuidString: reply.sessionID),
                  receipts.count < 8 || receipts[id] != nil || id == session else { return }
            receipts[id] = valid || receipts[id] == true
        }

        func readOutput(_ bytes: ArraySlice<UInt8>) {
            if let size = finalOutput?.count {
                if size + bytes.count <= 128 * 1024 {
                    finalOutput?.append(contentsOf: bytes)
                } else {
                    finalOutput = nil
                }
            }
            var start = bytes.startIndex
            while let newline = bytes[start...].firstIndex(of: 10) {
                appendLine(bytes[start..<newline])
                if !dropLine { parseLine() }
                partialLine.removeAll(keepingCapacity: true)
                dropLine = false
                start = bytes.index(after: newline)
            }
            appendLine(bytes[start...])
        }

        func readError(_ bytes: ArraySlice<UInt8>) {
            errorTail.append(contentsOf: bytes)
            if command.isAuthenticationError(errorTail, isOutput: false) { authenticationFailure = true }
            if errorTail.count > 1024 { errorTail.removeFirst(errorTail.count - 1024) }
        }

        func finishOutput() {
            if !dropLine, !partialLine.isEmpty { parseLine() }
            if let finalOutput { recordSession(command.sessionID(inFinalOutput: finalOutput)) }
        }

        private func appendLine(_ bytes: ArraySlice<UInt8>) {
            guard !dropLine else { return }
            if partialLine.count + bytes.count > 16 * 1024 {
                dropLine = true
                partialLine.removeAll(keepingCapacity: true)
            } else {
                partialLine.append(contentsOf: bytes)
            }
        }

        private func parseLine() {
            recordSession(command.sessionID(inOutputLine: partialLine))
            if command.isAuthenticationError(partialLine, isOutput: true) { authenticationFailure = true }
        }

        private func recordSession(_ observed: UUID?) {
            guard let observed else { return }
            if let session, session != observed { conflictingSession = true }
            session = observed
        }
    }

    private enum Failure: Error {
        case cliMissing, workspace, launch, timeout, authentication, cliExit, thread, output
        case wrongThread, unexpectedReply, noReceipt
    }

    private struct ProbeFailure: LocalizedError {
        let provider: HoldProvider
        let failure: Failure

        var errorDescription: String? {
            let event = provider == .gemini ? "AfterAgent" : "Stop"
            let cli = provider.name + (provider == .gemini ? "" : " CLI")
            switch failure {
            case .cliMissing: return "找不到可执行的 \(cli)。请安装后重试。"
            case .workspace: return "无法创建本地测试目录。"
            case .launch: return "无法启动 \(cli)。"
            case .timeout: return "等待 \(cli) 完成回复超时。"
            case .authentication:
                if provider == .codex { return "Codex CLI 未登录或登录已失效。请运行 codex login 后重试。" }
                return "\(cli) 认证失败。请在终端完成该来源的登录后重试。"
            case .cliExit: return "\(cli) 提前退出。请检查 CLI 版本、登录及网络连接后重试。"
            case .thread, .output: return "未能确认 \(cli) 返回的测试会话。"
            case .wrongThread: return "收到的 \(event) 回执与本次测试会话不匹配。"
            case .unexpectedReply: return "收到了本次 \(event) 回执，但回复里缺少预期的测试恢复条件。"
            case .noReceipt: return "\(provider.name) 已结束，但未收到本次 \(event) 回执。请重新检查配置并确认 Hook 已受信任。"
            }
        }
    }
}
