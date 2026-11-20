import Darwin
import Foundation
import Testing
@testable import AgentHold

@MainActor
struct ClaudeConnectionTests {
    @Test
    func asksBeforeWritingAndMergesTheLatestConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = ClaudeConnection(settings: fixture.settings)

        connection.prepare()
        guard case .needsApproval(let review) = connection.phase else {
            Issue.record("Expected to confirm the user-level Claude hook")
            return
        }
        #expect(review.configuration == fixture.file)
        #expect(review.command.hasSuffix(" --agent-hold-stop-hook --provider claude"))
        #expect(review.command.contains("'\\''"))
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))

        connection.reset()
        connection.approve()
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        connection.prepare()
        // An editor may save unrelated settings while the confirmation is open.
        try fixture.write("""
        {
          "permissions": {"deny": ["Bash(rm -rf *)"]},
          "hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "existing-pretool"}]}],
            "Stop": [{"hooks": [{"type": "prompt", "prompt": "existing-stop"}]}]
          }
        }
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.file.path)

        connection.approve()
        guard case .ready = connection.phase else {
            Issue.record("Expected confirmation to install the hook")
            return
        }
        let saved = try Data(contentsOf: fixture.file)
        let root = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let permissions = try #require(root["permissions"] as? [String: [String]])
        #expect(permissions["deny"] == ["Bash(rm -rf *)"])
        let events = try #require(root["hooks"] as? [String: [[String: Any]]])
        #expect(events["PreToolUse"]?.first?["matcher"] as? String == "Bash")
        let stop = try #require(events["Stop"])
        #expect(stop.count == 2)
        let priorHandlers = stop.first?["hooks"] as? [[String: String]]
        #expect(priorHandlers?.first?["prompt"] == "existing-stop")
        let newHandlers = stop.last?["hooks"] as? [[String: Any]]
        #expect(newHandlers?.first?["command"] as? String == review.command)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o640)

        connection.prepare()
        guard case .ready = connection.phase else {
            Issue.record("Expected the installed definition to be detected")
            return
        }
        try ClaudeHookConfiguration.install(at: fixture.file, executable: fixture.hook)
        #expect(try Data(contentsOf: fixture.file) == saved)
    }

    @Test
    func createsPrivateFirstConfigurationAndRejectsConcurrentWriters() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lock = fixture.file.deletingLastPathComponent().appendingPathComponent(".agent-hold-settings.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, 0o600)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: ClaudeHookConfiguration.Failure.concurrentChange) {
            try ClaudeHookConfiguration.install(at: fixture.file, executable: fixture.hook)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))

        #expect(flock(descriptor, LOCK_UN) == 0)
        try ClaudeHookConfiguration.install(at: fixture.file, executable: fixture.hook)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test
    func leavesDisabledMalformedAndSymlinkedSettingsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for contents in ["{\"disableAllHooks\": true}", "{\"hooks\": {\"Stop\": true}}", "{invalid"] {
            try fixture.write(contents)
            let connection = ClaudeConnection(settings: fixture.settings)
            connection.prepare()
            guard case .failed = connection.phase else {
                Issue.record("Expected the invalid or disabled configuration to stop preparation")
                continue
            }
            #expect(try String(contentsOf: fixture.file, encoding: .utf8) == contents)
        }

        let target = fixture.hook.deletingLastPathComponent().appendingPathComponent("other.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
        #expect(throws: ClaudeHookConfiguration.Failure.invalidSettings) {
            try ClaudeHookConfiguration.install(at: fixture.file, executable: fixture.hook)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "{}")
    }

    @Test
    func requiresConfirmationBeforeReplacingAnOldBundledHook() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldHook = fixture.hook.deletingLastPathComponent().appendingPathComponent("Old Agent App/AgentHoldHook")
        let command = ClaudeHookConfiguration.command(for: oldHook)
        let settings = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command, "timeout": 5]]]]]]
        let original = try JSONSerialization.data(withJSONObject: settings)
        try original.write(to: fixture.file)

        let connection = ClaudeConnection(settings: fixture.settings)
        connection.prepare()
        guard case .needsApproval = connection.phase else {
            Issue.record("Expected confirmation before switching to the new app path")
            return
        }
        #expect(try Data(contentsOf: fixture.file) == original)
        connection.approve()
        let saved = try Data(contentsOf: fixture.file)
        let root = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let events = try #require(root["hooks"] as? [String: [[String: Any]]])
        let stop = try #require(events["Stop"])
        let handlers = try #require(stop.first?["hooks"] as? [[String: Any]])
        #expect(stop.count == 1)
        #expect(handlers.first?["command"] as? String == ClaudeHookConfiguration.command(for: fixture.hook))
    }

    private struct Fixture {
        let root: URL
        let configurationDirectory: URL
        let hook: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHoldClaude-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            configurationDirectory = root.appendingPathComponent("configuration")
            try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
            hook = root.appendingPathComponent("Agent's Hold/AgentHoldHook")
            try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        }

        var file: URL { configurationDirectory.appendingPathComponent("settings.json") }

        var settings: ClaudeConnection.Settings {
            .init(home: root, configurationDirectory: configurationDirectory, hook: hook,
                  cli: URL(fileURLWithPath: "/usr/bin/true"))
        }

        func write(_ string: String) throws {
            try string.write(to: file, atomically: true, encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
