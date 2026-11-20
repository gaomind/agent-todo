import Foundation
import Testing
@testable import AgentHold

@MainActor
struct AntigravityConnectionTests {
    @Test
    func discoversAgyAndWaitsForApproval() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = AntigravityConnection(settings: fixture.settings)
        connection.approve()
        connection.check()
        guard case .needsApproval(let proposed) = connection.phase else {
            Issue.record("Expected the Antigravity hook confirmation")
            return
        }
        #expect(proposed.file == fixture.file)
        #expect(proposed.command.hasSuffix(" --agent-hold-stop-hook --provider antigravity"))
        #expect(proposed.command.contains("'\\''"))
        #expect(connection.cliURL == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.deletingLastPathComponent().path))
        connection.reset()
        connection.approve()
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))

        connection.check()
        connection.approve()
        #expect(connection.cliURL == fixture.cli)
        #expect(connection.probeConfiguration == fixture.file)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file))
        let root = try #require(json as? [String: [String: [[String: Any]]]])
        let handler = try #require(root["agent-todo"]?["Stop"]?.first)
        #expect(handler["type"] as? String == "command")
        #expect(handler["command"] as? String == proposed.command)
        #expect(handler["timeout"] as? Int == 10)
    }

    @Test
    func mergesWithoutReserializingOtherHooksOrEnablingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = """
        {"someone-else":{"enabled":false,"Stop":[{"command":"other"}]},
         "a-number":0.12345678901234567890123456789}
        """
        try fixture.write(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.file.path)
        let connection = AntigravityConnection(settings: fixture.settings)
        connection.check()
        connection.approve()
        #expect(connection.cliURL == fixture.cli)
        let bytes = try Data(contentsOf: fixture.file)
        #expect(String(decoding: bytes, as: UTF8.self).hasPrefix(String(original.dropLast()) + ","))
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? Int == 0o640)
        connection.check()
        #expect(connection.cliURL == fixture.cli)
        connection.approve()
        #expect(try Data(contentsOf: fixture.file) == bytes)
    }

    @Test
    func installsIntoAnEmptyObjectAndRecognizesAnExplicitlyEnabledHook() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("{  }")
        let connection = AntigravityConnection(settings: fixture.settings)
        connection.check()
        connection.approve()
        #expect(connection.cliURL == fixture.cli)

        let installed = try Data(contentsOf: fixture.file)
        var root = try #require(JSONSerialization.jsonObject(with: installed) as? [String: [String: Any]])
        root["agent-todo"]?["enabled"] = true
        let enabled = try JSONSerialization.data(withJSONObject: root)
        try enabled.write(to: fixture.file)
        connection.check()
        #expect(connection.cliURL == fixture.cli)
        connection.approve()
        #expect(try Data(contentsOf: fixture.file) == enabled)
    }

    @Test
    func leavesConflictingDisabledAndInvalidSettingsIntact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = AntigravityConnection(settings: fixture.settings)
        for original in [
            #"{"agent-todo":{"Stop":[{"command":"my hook"}]}}"#,
            #"{"agent-todo":{"enabled":false}}"#,
            #"{"agent-todo":null}"#,
            #"{"another":{} ,}"#,
            #"["not a hook object"]"#,
            "{invalid",
        ] {
            try fixture.write(original)
            connection.check()
            guard case .failed = connection.phase else {
                Issue.record("Expected an explicit conflict or format error")
                continue
            }
            connection.approve()
            #expect(try String(contentsOf: fixture.file, encoding: .utf8) == original)
        }
    }

    @Test
    func approvalDoesNotReplaceAnEditedConfigurationOrSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = AntigravityConnection(settings: fixture.settings)
        try fixture.write("{}")
        connection.check()
        let edited = #"{"other":{"enabled":false}}"#
        try fixture.write(edited)
        connection.approve()
        guard case .failed = connection.phase else {
            Issue.record("Expected a changed file to require another check")
            return
        }
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == edited)

        try FileManager.default.removeItem(at: fixture.file)
        let outside = fixture.home.appendingPathComponent("other.json")
        try Data(edited.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: outside)
        connection.check()
        connection.approve()
        guard case .failed = connection.phase else {
            Issue.record("Expected the configuration symlink to be rejected")
            return
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == edited)
    }

    @Test
    func missingHelperDoesNotOfferToWriteConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.hook)
        let connection = AntigravityConnection(settings: fixture.settings)
        connection.check()
        guard case .failed = connection.phase else {
            Issue.record("Expected failure when the capture helper is missing")
            return
        }
        connection.approve()
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    private struct Fixture {
        let home: URL
        var hook: URL { home.appendingPathComponent("Agent's Todo.app/Contents/MacOS/AgentHoldHook") }
        var cli: URL { home.appendingPathComponent(".local/bin/agy") }
        var file: URL { home.appendingPathComponent(".gemini/config/hooks.json") }
        var settings: AntigravityConnection.Settings {
            .init(home: home, hook: hook, environment: [:])
        }

        init() throws {
            home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString)
            for path in [hook, cli] {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
        }

        func write(_ contents: String) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}
