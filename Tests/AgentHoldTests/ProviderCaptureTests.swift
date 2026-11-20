import AgentHoldCaptureSupport
import Foundation
import Testing
@testable import AgentHold

@MainActor
struct ProviderCaptureTests {
    @Test
    func preservesLegacyOriginAndDoesNotTreatUnknownAsCodex() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.reply(.codex, turn: "turn")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var old = json
        old.removeValue(forKey: "provider")
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(CodexReply.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.provider == .codex)
        let store = HoldStore(file: fixture.file)
        #expect(store.ingest(legacy))
        var future = json
        future["provider"] = "another-service"
        let unknown = try decoder.decode(CodexReply.self, from: JSONSerialization.data(withJSONObject: future))
        #expect(unknown.provider == .unknown)
        #expect(store.ingest(unknown))
        #expect(store.items.map(\.provider) == [.codex])
        var rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [[String: Any]])
        rows[0]["provider"] = "another-service"
        try JSONSerialization.data(withJSONObject: rows).write(to: fixture.file)
        let reopened = HoldStore(file: fixture.file)
        let preserved = try #require(reopened.items.first)
        #expect(preserved.provider == .unknown)
        #expect(preserved.resumeCommand.isEmpty)
    }

    @Test
    func isolatesCollisionReplayAndReplacementAcrossProviders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = HoldStore(file: fixture.file)
        for provider in [HoldProvider.codex, .claude, .grok, .gemini] {
            let reply = fixture.reply(provider, turn: "same-turn")
            #expect(store.ingest(reply))
            #expect(store.ingest(reply))
        }
        #expect(store.items.count == 4)
        #expect(store.ingest(fixture.reply(.claude, turn: "same-turn", at: 1, message: "回复无挂起事项。")))
        #expect(Set(store.items.map(\.provider)) == [.codex, .grok, .gemini])
        #expect(HoldStore(file: fixture.file).items.map(\.provider) == [.codex, .grok, .gemini])

        let noTurn = fixture.reply(.claude, turn: nil, at: 2)
        #expect(store.ingest(noTurn))
        #expect(store.ingest(fixture.reply(.claude, turn: nil, at: 3)))
        let claude = try #require(store.items.first { $0.provider == .claude })
        store.changeStatus(of: claude.id, to: .completed)
        #expect(store.ingest(noTurn))
        #expect(store.ingest(fixture.reply(.claude, turn: nil, at: 3)))
        #expect(store.items.filter { $0.provider == .claude }.count == 1)
        #expect(store.ingest(fixture.reply(.claude, turn: nil, at: 20)))
        #expect(store.items.filter { $0.provider == .claude }.map(\.status) == [.completed, .waiting])
    }

    @Test
    func copiesEachOriginAndUsesTheRightResumeCommand() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = HoldStore(file: fixture.file)
        for provider in [HoldProvider.codex, .claude, .grok, .gemini] {
            #expect(store.ingest(fixture.reply(provider, turn: "turn")))
        }
        let session = fixture.session.lowercased()
        let path = #"'/tmp/John'"'"'s project'"#
        let expected: [(String, String)] = [
            ("⌘ Codex", "codex -C \(path) resume \(session)"),
            ("✳ Claude Code", "cd \(path) && claude --resume \(session)"),
            ("◉ Grok", "grok --cwd \(path) --resume \(session)"),
            ("✦ Gemini CLI", "cd \(path) && gemini --resume \(session)"),
        ]
        for (item, expectation) in zip(store.items, expected) {
            let (label, resume) = expectation
            #expect(item.provider.label == label)
            #expect(item.copyText(sourceContext: store.sourceContext(for: item)).hasPrefix(label + " · 待办\n"))
            #expect(item.resumeContext.hasPrefix(label + " · 待办\n"))
            #expect(item.resumeCommand == resume)
            #expect(store.sourceContext(for: item)?.text == fixture.message)
        }
    }

    @Test
    func helperDecodesBothVendorsAndIgnoresShutdown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let text = fixture.message
        #expect(try fixture.hook("claude", [
            "hook_event_name": "Stop", "session_id": fixture.session, "prompt_id": "claude-prompt",
            "turn_id": "secondary", "last_assistant_message": text,
        ]).map(\.turnID) == ["claude-prompt"])
        let grok = try #require(try fixture.hook("grok", [
            "hookEventName": "stop", "sessionId": fixture.session, "promptId": "grok-prompt",
            "lastAssistantMessage": text, "reason": "end_turn",
        ]).first)
        #expect(grok.provider == .grok)
        #expect(grok.turnID == "grok-prompt")
        #expect(grok.message == text)
        let snake = try #require(try fixture.hook("grok", [
            "hook_event_name": "Stop", "session_id": fixture.session, "promptId": "snake-prompt",
            "last_assistant_message": text, "reason": "end_turn",
        ]).first)
        #expect(snake.turnID == "snake-prompt")
        #expect(try fixture.hook("grok", [
            "hookEventName": "stop", "sessionId": fixture.session, "promptId": "shutdown",
            "lastAssistantMessage": text, "reason": "shutdown",
        ]).isEmpty)
        #expect(try fixture.hook("unknown", ["hook_event_name": "Stop", "session_id": fixture.session,
                                             "last_assistant_message": text]).isEmpty)
    }

    @Test
    func geminiAfterAgentCapturesOnlyFinalTextAndKeepsStableReplayTime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let timestamp = iso.format(fixture.timestamp)
        let payload = [
            "hook_event_name": "AfterAgent", "session_id": fixture.session, "cwd": "/tmp/example",
            "prompt_response": fixture.message, "prompt": "恢复条件：用户文字不能被采集。",
            "transcript_path": "/must-not-open.json", "timestamp": timestamp,
        ]
        let received = try #require(try fixture.hook("gemini", payload).first)
        #expect(received.provider == .gemini)
        #expect(received.turnID == nil)
        #expect(received.message == fixture.message)
        #expect(received.receivedAt == (try iso.parse(timestamp)))
        let store = HoldStore(file: fixture.file)
        #expect(store.ingest(received))
        let initial = try #require(store.items.first)
        store.changeStatus(of: initial.id, to: .completed)
        let replay = try #require(try fixture.hook("gemini", payload).first)
        #expect(replay.receivedAt == received.receivedAt)
        #expect(store.ingest(replay))
        #expect(store.items.count == 1)

        var next = payload
        next["timestamp"] = iso.format(Date().addingTimeInterval(1))
        let repeated = try #require(try fixture.hook("gemini", next).first)
        #expect(store.ingest(repeated))
        #expect(store.items.map(\.status) == [.completed, .waiting])
        #expect(store.items.allSatisfy { $0.provider == .gemini && $0.turnID == nil })

        next.removeValue(forKey: "prompt_response")
        #expect(try fixture.hook("gemini", next).isEmpty)
        next["prompt_response"] = fixture.message
        next["hook_event_name"] = "AfterTool"
        #expect(try fixture.hook("gemini", next).isEmpty)
    }

    private struct Fixture {
        let directory: URL
        let session = UUID().uuidString
        let message = "恢复条件：等待审批。"
        let timestamp = Date().addingTimeInterval(-10)
        var file: URL { directory.appendingPathComponent("holds.json") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func reply(_ provider: HoldProvider, turn: String?, at elapsed: TimeInterval = 0,
                   message: String? = nil) -> CodexReply {
            CodexReply(sessionID: session, turnID: turn, cwd: "/tmp/John's project",
                       message: message ?? self.message, receivedAt: timestamp.addingTimeInterval(elapsed),
                       provider: provider)
        }

        func hook(_ provider: String, _ payload: [String: String]) throws -> [CodexReply] {
            let input = directory.appendingPathComponent("input")
            try JSONEncoder().encode(payload).write(to: input)
            let queue = directory.appendingPathComponent(UUID().uuidString)
            let binaries = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
            let helper = Process()
            helper.executableURL = binaries.appendingPathComponent("AgentHoldHook")
            helper.arguments = ["--agent-hold-stop-hook", "--provider", provider, "--spool", queue.path]
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            helper.standardInput = handle
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            helper.waitUntilExit()
            #expect(helper.terminationStatus == 0)
            return try ReplySpool(root: queue).pending().compactMap { entry in
                try entry.data.map { try JSONDecoder().decode(CodexReply.self, from: $0) }
            }
        }
    }

    private final class Marker: NSObject {}
}
