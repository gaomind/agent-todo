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

    @Published private(set) var state = State.idle
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

    func start(cli: URL) {
        guard task == nil else { return }
        state = .running
        task = Task {
            defer {
                active = nil
                task = nil
            }
            do {
                try await run(cli: cli)
                state = .passed
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = .failed(error.localizedDescription)
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
        guard reply.provider == .codex, let cwd = reply.cwd, cwd.hasPrefix("/") else { return false }
        let directory = Self.canonical(URL(fileURLWithPath: cwd, isDirectory: true))
        let name = directory.lastPathComponent
        guard directory.deletingLastPathComponent() == Self.temporaryDirectory,
              name.hasPrefix(Self.directoryPrefix),
              let token = UUID(uuidString: String(name.dropFirst(Self.directoryPrefix.count))),
              reply.message.utf8.count <= HoldDetector.maximumReplyBytes,
              reply.message.localizedCaseInsensitiveContains(token.uuidString) else { return false }
        if let active, directory == active.directory {
            active.accept(reply, conditions: conditions)
        }

        // Match both the private workspace and its random marker, including
        // for callbacks arriving after cancellation or app restart.
        return true
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

    private func run(cli: URL) async throws {
        try Task.checkCancellation()
        guard cli.isFileURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw Failure.cliMissing
        }
        let attempt = Attempt(root: Self.temporaryDirectory)
        do {
            try FileManager.default.createDirectory(at: attempt.directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.workspace
        }
        defer { try? FileManager.default.removeItem(at: attempt.directory) }
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
        var environment = ProcessInfo.processInfo.environment
        // The application's configuration button manages the default Codex home.
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        let instructions = "这是连接测试。不要调用任何工具或读取文件。只原样输出下面一行，不要添加其他内容。\n恢复条件：\(attempt.condition)。"
        process.arguments = [
            "exec", "--cd", attempt.directory.path, "--skip-git-repo-check", "--ephemeral",
            "--json", "--color", "never", "--sandbox", "read-only",
            "--disable", "shell_tool", "--disable", "unified_exec",
            "--disable", "apps", "--disable", "plugins", "--disable", "code_mode",
            "--disable", "image_generation", "--disable", "multi_agent_v2",
            "--disable", "computer_use", "--disable", "browser_use", "--disable", "browser_use_external",
            "-c", "approval_policy=never", "-c", "web_search=disabled",
            "-c", "project_doc_max_bytes=0", "-c", "notify=[]",
            "--", instructions,
        ]
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
            try Self.drain(stdout, stderr, attempt: attempt)
            try Task.checkCancellation()
        } catch {
            await Self.terminate(process, ownsProcessGroup: ownsProcessGroup)
            throw error
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw attempt.authenticationFailure ? Failure.authentication : Failure.cliExit
        }
        guard let session = attempt.session, !attempt.conflictingSession else { throw Failure.thread }

        let receiptDeadline = min(deadline, clock.now + receiptTimeout)
        while clock.now < receiptDeadline {
            try Task.checkCancellation()
            if let valid = attempt.receipts[session] {
                guard valid else { throw Failure.unexpectedReply }
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        if !attempt.receipts.isEmpty { throw Failure.wrongThread }
        throw Failure.noReceipt
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
        private let token = UUID().uuidString.lowercased()
        let directory: URL
        var condition: String { "等待连接测试确认 \(token) 后继续" }
        var session: UUID?
        var conflictingSession = false
        var receipts: [UUID: Bool] = [:]

        private var partialLine = Data()
        private var dropLine = false
        private var errorTail = Data()
        private var authenticationEvent = false
        var authenticationFailure: Bool {
            authenticationEvent || Self.isAuthenticationError(errorTail)
        }

        init(root: URL) {
            directory = root.appendingPathComponent(CodexLiveProbe.directoryPrefix + token, isDirectory: true)
        }

        func accept(_ reply: CodexReply, conditions: [String]) {
            guard let id = UUID(uuidString: reply.sessionID),
                  receipts.count < 8 || receipts[id] != nil || id == session else { return }
            let valid = conditions.contains(condition)
            receipts[id] = valid || receipts[id] == true
        }

        func readOutput(_ bytes: ArraySlice<UInt8>) {
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
            if Self.isAuthenticationError(errorTail) { authenticationEvent = true }
            if errorTail.count > 1024 { errorTail.removeFirst(errorTail.count - 1024) }
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
            guard let event = try? JSONDecoder().decode(Event.self, from: partialLine) else { return }
            if event.type == "thread.started", let thread = event.threadId {
                if let session, session != thread { conflictingSession = true }
                session = thread
            } else if event.type == "error" || event.type == "turn.failed" {
                authenticationEvent = authenticationEvent || Self.isAuthenticationError(partialLine)
            }
        }

        private static func isAuthenticationError(_ data: Data) -> Bool {
            let text = String(decoding: data, as: UTF8.self).lowercased()
            return ["401 unauthorized", "invalid_api_key", "not logged in", "codex login",
                    "authentication required", "missing bearer"].contains(where: text.contains)
        }

        private struct Event: Decodable {
            let type: String
            let threadId: UUID?

            enum CodingKeys: String, CodingKey {
                case type
                case threadId = "thread_id"
            }
        }
    }

    private enum Failure: LocalizedError {
        case cliMissing, workspace, launch, timeout, authentication, cliExit, thread, output
        case wrongThread, unexpectedReply, noReceipt

        var errorDescription: String? {
            switch self {
            case .cliMissing: "找不到可执行的 Codex CLI。请安装 Codex CLI 后重试。"
            case .workspace: "无法创建本地测试目录。"
            case .launch: "无法启动 Codex CLI。"
            case .timeout: "等待 Codex CLI 完成回复超时。"
            case .authentication: "Codex CLI 未登录或登录已失效。请运行 codex login 后重试。"
            case .cliExit: "Codex CLI 提前退出。请检查 CLI 版本、登录及网络连接后重试。"
            case .thread, .output: "未能读取 Codex CLI 返回的测试会话信息。"
            case .wrongThread: "收到的 Stop 回执与本次测试会话不匹配。"
            case .unexpectedReply: "收到了本次 Stop 回执，但回复里缺少预期的测试恢复条件。"
            case .noReceipt: "Codex 已结束，但未收到本次 Stop 回执。请在「连接」中点击「重新检查配置」，核对并信任 Agent Todo 的 Stop Hook 后重试。"
            }
        }
    }
}
