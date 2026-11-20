import Foundation
import Testing
@testable import AgentHold

struct CaptureSelfTestTests {
    @MainActor
    @Test
    func runsTheRealHookAndRemovesItsTemporaryData() async throws {
        let binaries = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
        let hook = binaries.appendingPathComponent("AgentHoldHook")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let condition = try await CaptureSelfTest.run(hook: hook, temporaryDirectory: folder)

        #expect(condition == "收到测试审批结果后继续处理")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @MainActor
    @Test
    func timesOutTheHelperAndRemovesItsTemporaryData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hook = folder.appendingPathComponent("slow-hook")
        try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)

        do {
            _ = try await CaptureSelfTest.run(hook: hook, temporaryDirectory: folder, timeout: .milliseconds(100))
            Issue.record("The unresponsive hook should have timed out.")
        } catch {
            #expect(error.localizedDescription.contains("超时"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["slow-hook"])
    }

    @MainActor
    @Test
    func cancellationRemovesThePendingTestData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hook = folder.appendingPathComponent("slow-hook")
        try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)

        let task = Task { try await CaptureSelfTest.run(hook: hook, temporaryDirectory: folder) }
        defer { task.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["slow-hook"] {
            try #require(clock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["slow-hook"])
    }

    private final class TestBundleMarker: NSObject {}
}
