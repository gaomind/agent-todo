import AgentHoldCaptureSupport
import Foundation
import Testing
@testable import AgentHold

struct CaptureTests {
    @Test
    func mergesKnownConfigurationAndLeavesUnknownConfigurationUntouched() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let executable = folder.appending(path: "program with ' spaces")
        try Data("#!/bin/sh\nprintf '%s' \"$1\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let newFile = folder.appending(path: "new/hooks.json")
        try CodexHookConfiguration.install(at: newFile, executable: executable)
        #expect(FileManager.default.fileExists(atPath: newFile.path))

        let file = folder.appending(path: "hooks.json")
        try Data("""
        {"description":"existing", "hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-stop"}]}],"SessionStart":[]}}
        """.utf8).write(to: file)
        try CodexHookConfiguration.install(at: file, executable: executable)
        let merged = try Data(contentsOf: file)
        let root = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let groups = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(root["description"] as? String == "existing")
        #expect(hooks["SessionStart"] is [Any])
        #expect(groups.count == 2)
        let first = try #require(groups.first?["hooks"] as? [[String: Any]])
        #expect(first.first?["command"] as? String == "existing-stop")
        let last = try #require(groups.last?["hooks"] as? [[String: Any]])
        let command = try #require(last.first?["command"] as? String)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "--agent-hold-stop-hook")
        try CodexHookConfiguration.install(at: file, executable: executable)
        #expect(try Data(contentsOf: file) == merged)

        for content in [
            #"{"hooks":{"Stop":[{"hooks":7}]}}"#,
            #"{"hooks":{"SessionStart":[{"hooks":[{"type":"unknown"}]}]}}"#,
            #"{"hooks":{},"unrecognized":true}"#,
        ] {
            let invalid = Data(content.utf8)
            try invalid.write(to: file)
            #expect(throws: (any Error).self) {
                try CodexHookConfiguration.install(at: file, executable: executable)
            }
            #expect(try Data(contentsOf: file) == invalid)
        }
    }

    @MainActor
    @Test
    func preservesUnreadEventsUntilTheCallbackCommits() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spool = ReplySpool(root: folder)
        let encoder = JSONEncoder()
        try spool.append(Data("invalid JSON".utf8))
        for message in ["恢复条件：first", "恢复条件：second"] {
            let record = CodexReply(sessionID: UUID().uuidString, cwd: "/example", message: message, receivedAt: Date())
            try spool.append(encoder.encode(record))
        }

        let probe = CommitProbe()
        let capture = CodexCapture(spool: spool) { _, conditions in
            probe.delivered.append(contentsOf: conditions)
            return probe.commitsAllowed
        }
        capture.start()
        try await waitUntil { probe.delivered.count == 1 }
        #expect(probe.delivered == ["first"])
        try await waitUntil { try spool.pending().count == 2 }

        probe.commitsAllowed = true
        try await waitUntil { probe.delivered.count == 3 }
        #expect(probe.delivered == ["first", "first", "second"])
        try await waitUntil { try spool.pending().isEmpty }
    }

    @MainActor
    @Test
    func lateProbeReceiptsNeverUpdateTheOrdinaryConversationTimestamp() async throws {
        let temporary = FileManager.default.temporaryDirectory
        let folder = temporary.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spool = ReplySpool(root: folder)
        let probe = CodexLiveProbe()
        let receivedAt = Date()
        let encoder = JSONEncoder()
        let capture = CodexCapture(spool: spool, consumeProbe: probe.accept) { _, conditions in
            conditions.isEmpty
        }

        let token = UUID()
        let probePath = temporary.appending(path: "AgentHoldLiveProbe-\(token.uuidString)").path
        func append(cwd: String, message: String, at date: Date) throws {
            let reply = CodexReply(sessionID: UUID().uuidString, cwd: cwd, message: message, receivedAt: date)
            try spool.append(encoder.encode(reply))
        }

        try append(cwd: probePath, message: "恢复条件：验证 \(token.uuidString)", at: receivedAt)
        capture.start()
        try await waitUntil { try spool.pending().isEmpty }
        #expect(capture.lastOrdinaryReceivedAt == nil)

        try append(cwd: "/example", message: "普通回复，无待办。", at: receivedAt)
        try append(cwd: probePath, message: "恢复条件：验证 \(token.uuidString)", at: receivedAt.addingTimeInterval(30))
        try await waitUntil { try spool.pending().isEmpty }
        #expect(capture.lastOrdinaryReceivedAt == receivedAt)
        await capture.stop()
    }

    @MainActor
    @Test
    func recordsReceiptsSeparatelyAndNeverRoutesOtherProvidersToTheCodexProbe() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spool = ReplySpool(root: folder)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var ordinary: [HoldProvider] = []
        var tested: [HoldProvider] = []
        let capture = CodexCapture(spool: spool, consumeProbe: { reply, _ in
            tested.append(reply.provider)
            return reply.message == "test"
        }) { reply, _ in
            ordinary.append(reply.provider)
            return true
        }
        for (provider, offset, message) in [
            (HoldProvider.claude, 1.0, "test"), (.grok, 2.0, "grok"),
            (.codex, 3.0, "test"), (.codex, 4.0, "codex"), (.unknown, 5.0, "ignore"),
            (.gemini, 6.0, "gemini"),
        ] {
            let reply = CodexReply(sessionID: UUID().uuidString, cwd: nil, message: message,
                                   receivedAt: start.addingTimeInterval(offset), provider: provider)
            try spool.append(JSONEncoder().encode(reply))
        }
        capture.start()
        try await waitUntil { try spool.pending().isEmpty }
        await capture.stop()
        #expect(ordinary == [.claude, .grok, .codex, .gemini])
        #expect(tested == [.codex, .codex])
        #expect(capture.lastOrdinaryReceivedAt == start.addingTimeInterval(4))
        #expect(capture.lastReceivedAt(for: .claude) == start.addingTimeInterval(1))
        #expect(capture.lastReceivedAt(for: .grok) == start.addingTimeInterval(2))
        #expect(capture.lastReceivedAt(for: .gemini) == start.addingTimeInterval(6))
        #expect(capture.lastReceivedAt(for: .unknown) == nil)
    }

    @MainActor
    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while try !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for the capture task.")
                throw WaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private final class CommitProbe {
        var commitsAllowed = false
        var delivered: [String] = []
    }

    private enum WaitError: Error {
        case timedOut
    }
}
