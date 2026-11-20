import AgentHoldCaptureSupport
import Darwin
import Foundation
import Testing
@testable import AgentHold

struct HookCaptureIntegrationTests {
    @MainActor
    @Test
    func savesAWaitingItemFromARealCodexStopHook() async throws {
        let binaries = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
        let hook = binaries.appendingPathComponent("AgentHoldHook")
        try #require(FileManager.default.isExecutableFile(atPath: hook.path))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }

        let queue = folder.appendingPathComponent("ReplySpool")
        let session = UUID()
        let turn = UUID().uuidString
        let condition = "收到测试审批结果后继续处理"
        let payload = [
            "hook_event_name": "Stop",
            "session_id": session.uuidString,
            "turn_id": turn,
            "last_assistant_message": "我已完成前置检查。恢复条件：\(condition)。",
        ]
        try await runHook(hook, in: folder, queue: queue, payload: payload)

        let spool = ReplySpool(root: queue)
        try #require(spool.pending().count == 1)
        let file = folder.appendingPathComponent("holds.json")
        let store = HoldStore(file: file)
        let capture = CodexCapture(spool: spool) { reply, conditions in
            store.ingest(reply, conditions: conditions)
        }
        capture.start()
        do {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while store.items.isEmpty {
                try #require(store.errorMessage == nil)
                try #require(clock.now < deadline, "The capture did not save a waiting item.")
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            await capture.stop()
            throw error
        }
        await capture.stop()

        let saved = HoldStore(file: file)
        #expect(saved.errorMessage == nil)
        #expect(saved.items.count == 1)
        let item = try #require(saved.items.first)
        #expect(item.provider == .codex)
        #expect(item.sessionID == session)
        #expect(item.turnID == turn)
        #expect(item.status == .waiting)
        #expect(item.condition == condition)
        #expect(item.evidence == condition)
    }

    private func runHook(_ hook: URL, in folder: URL, queue: URL, payload: [String: String]) async throws {
        let input = folder.appendingPathComponent("stop.json")
        try JSONEncoder().encode(payload).write(to: input)
        let stdin = try FileHandle(forReadingFrom: input)
        defer { try? stdin.close() }

        let process = Process()
        process.executableURL = hook
        process.currentDirectoryURL = folder
        process.arguments = ["--agent-hold-stop-hook", "--spool", queue.path]
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while process.isRunning {
            try #require(clock.now < deadline, "The hook did not exit.")
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(process.terminationReason == .exit && process.terminationStatus == 0)
    }

    private final class TestBundleMarker: NSObject {}
}
