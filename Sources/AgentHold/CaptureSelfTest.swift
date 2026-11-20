import AgentHoldCaptureSupport
import Combine
import Darwin
import Foundation

@MainActor
final class CaptureSelfTest: ObservableObject {
    enum State {
        case idle
        case running
        case cancelling
        case passed(String)
        case failed(String)
        case cancelled
    }

    @Published private(set) var state = State.idle
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        state = .running
        task = Task {
            defer { task = nil }
            do {
                state = .passed(try await Self.run(hook: Self.bundledHook))
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard let task else { return }
        state = .cancelling
        task.cancel()
    }

    func cancelAndWait() async {
        cancel()
        await task?.value
    }

    private static var bundledHook: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentHoldHook")
    }

    static func run(
        hook: URL?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        timeout: Duration = .seconds(5)
    ) async throws -> String {
        try Task.checkCancellation()
        guard let hook, FileManager.default.isExecutableFile(atPath: hook.path) else {
            throw Failure.hookMissing
        }
        let manager = FileManager.default
        let directory = temporaryDirectory.appendingPathComponent("AgentHoldTest-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.temporaryStorage
        }
        defer { try? manager.removeItem(at: directory) }

        let session = UUID()
        let turn = UUID().uuidString
        let expected = "收到测试审批结果后继续处理"
        let input = directory.appendingPathComponent("stop.json")
        let payload = [
            "hook_event_name": "Stop",
            "session_id": session.uuidString,
            "turn_id": turn,
            "last_assistant_message": "我已完成前置检查。恢复条件：\(expected)。",
        ]
        let stdin: FileHandle
        do {
            try JSONEncoder().encode(payload).write(to: input)
            stdin = try FileHandle(forReadingFrom: input)
        } catch {
            throw Failure.temporaryStorage
        }
        defer { try? stdin.close() }

        let queue = directory.appendingPathComponent("ReplySpool", isDirectory: true)
        let process = Process()
        process.executableURL = hook
        process.currentDirectoryURL = directory
        process.arguments = ["--agent-hold-stop-hook", "--spool", queue.path]
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        do {
            try process.run()
        } catch {
            throw Failure.hookLaunch
        }
        defer {
            if process.isRunning {
                // This is the single helper launched above. Reap it before removing its spool.
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        while process.isRunning {
            guard clock.now < deadline else { throw Failure.hookTimeout }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.hookExit
        }

        let spool = ReplySpool(root: queue)
        guard (try? spool.pending().count) == 1 else { throw Failure.hookOutput }

        let file = directory.appendingPathComponent("holds.json")
        let store = HoldStore(file: file)
        let capture = CodexCapture(spool: spool) { reply, conditions in
            store.ingest(reply, conditions: conditions)
        }
        capture.start()
        do {
            while store.items.isEmpty {
                guard store.errorMessage == nil else { throw Failure.temporaryStorage }
                guard clock.now < deadline else { throw Failure.recognition }
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            await capture.stop()
            throw error
        }
        await capture.stop()
        try Task.checkCancellation()

        let saved = HoldStore(file: file)
        guard saved.errorMessage == nil else { throw Failure.temporaryStorage }
        guard saved.items.count == 1, let item = saved.items.first,
              item.sessionID == session, item.turnID == turn, item.status == .waiting,
              item.condition == expected, item.evidence == expected else {
            throw Failure.recognition
        }
        return item.condition
    }

    private enum Failure: LocalizedError {
        case hookMissing
        case hookLaunch
        case hookTimeout
        case hookExit
        case hookOutput
        case temporaryStorage
        case recognition

        var errorDescription: String? {
            switch self {
            case .hookMissing:
                "找不到 AgentHoldHook。请打开完整的 Agent 待办应用后重试。"
            case .hookLaunch, .hookExit:
                "测试 Hook 无法正常运行。请重新打开应用后重试。"
            case .hookTimeout:
                "等待测试 Hook 超时。请重试。"
            case .hookOutput:
                "测试 Hook 未写入预期的模拟回复。请重新打开应用后重试。"
            case .temporaryStorage:
                "测试无法读写临时数据。请检查本机临时目录的访问权限和剩余空间。"
            case .recognition:
                "未从磁盘读回预期的恢复条件。请重试。"
            }
        }
    }
}
