import Foundation
import Testing
@testable import AgentHold

struct GrokConnectionTests {
    @Test
    func testResolvesDefaultAndAbsoluteGrokHome() throws {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(try GrokConnection.grokHome(userHome: home, environment: [:]).path == "/Users/test/.grok")
        #expect(try GrokConnection.grokHome(userHome: home,
                                            environment: ["GROK_HOME": "/tmp/my grok"]).path == "/tmp/my grok")
        #expect(throws: GrokConnectionFailure.relativeHome) {
            try GrokConnection.grokHome(userHome: home, environment: ["GROK_HOME": ".grok-local"])
        }
    }

    @Test
    func testInstallsPersonalStopHookWithoutReplacingOtherFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = GrokHookConfiguration(
            grokHome: directory,
            executable: URL(fileURLWithPath: "/Applications/Agent's Hold.app/Contents/MacOS/AgentHoldHook")
        )
        try FileManager.default.createDirectory(at: hook.directory, withIntermediateDirectories: true)
        let unrelated = hook.directory.appendingPathComponent("personal.json")
        let original = Data("{}".utf8)
        try original.write(to: unrelated)

        try hook.install()

        let saved = try Data(contentsOf: hook.file)
        let root = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let events = try #require(root["hooks"] as? [String: [[String: Any]]])
        let actions = try #require(events["Stop"]?.first?["hooks"] as? [[String: Any]])
        #expect(actions.count == 1)
        #expect(actions.first?["type"] as? String == "command")
        #expect(actions.first?["command"] as? String ==
                       "exec '/Applications/Agent'\\''s Hold.app/Contents/MacOS/AgentHoldHook' --agent-hold-stop-hook --provider grok")
        #expect(try Data(contentsOf: unrelated) == original)
        #expect(throws: GrokConnectionFailure.existingConfiguration(hook.file.path)) { try hook.install() }
        #expect(try Data(contentsOf: hook.file) == saved)
    }

    @Test
    func testInspectionRequiresOneMatchingPersonalStopHook() throws {
        let configuration = GrokHookConfiguration(
            grokHome: URL(fileURLWithPath: "/tmp/grok-home"),
            executable: URL(fileURLWithPath: "/tmp/AgentHoldHook")
        )
        let entry: [String: Any] = [
            "event": "stop", "hookType": "command", "target": configuration.command,
            "source": ["type": "user", "path": configuration.directory.path], "matcher": NSNull(),
        ]
        func inspect(_ hooks: [[String: Any]]) throws -> GrokInspection {
            let bytes = try JSONSerialization.data(withJSONObject: ["grokVersion": "1.0.89", "hooks": hooks])
            return try JSONDecoder().decode(GrokInspection.self, from: bytes)
        }

        #expect(try inspect([entry]).contains(configuration))
        #expect(try !inspect([entry, entry]).contains(configuration))
        var projectHook = entry
        projectHook["source"] = ["type": "project", "path": configuration.directory.path]
        #expect(try !inspect([projectHook]).contains(configuration))
        var otherHome = entry
        otherHome["source"] = ["type": "user", "path": "/tmp/elsewhere/hooks"]
        #expect(try !inspect([otherHome]).contains(configuration))
        var filteredHook = entry
        filteredHook["matcher"] = "Bash"
        #expect(try !inspect([filteredHook]).contains(configuration))
    }
}
