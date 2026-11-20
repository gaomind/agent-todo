import Foundation
import Testing
@testable import AgentHold

@MainActor
struct GeminiConnectionTests {
    @Test
    func findsGlobalNpmInstallUnderNVMWithoutShellPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let version = fixture.home.appendingPathComponent(".nvm/versions/node/v22.23.1")
        let cli = version.appendingPathComponent("bin/gemini")
        let script = version.appendingPathComponent("lib/node_modules/@google/gemini-cli/bundle/gemini.js")
        try Fixture.makeExecutable(script)
        try Fixture.makeExecutable(version.appendingPathComponent("bin/node"))
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: script)

        let settings = GeminiConnection.Settings(home: fixture.home, hook: fixture.hook, environment: [:])
        #expect(try settings.findCLI() == cli)

        let userBin = fixture.home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        let linkedCLI = userBin.appendingPathComponent("gemini")
        try FileManager.default.createSymbolicLink(at: linkedCLI, withDestinationURL: script)
        #expect(try settings.findCLI() == linkedCLI)
        let environment = ProviderCLI.launchEnvironment(for: linkedCLI, environment: ["PATH": ".:/usr/bin:/bin"])
        #expect(environment["PATH"]?.split(separator: ":").prefix(3).map(String.init) == [
            userBin.path, version.appendingPathComponent("bin").path, "/usr/bin",
        ])
    }

    @Test
    func asksBeforeWritingAndPreservesExistingHooks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = GeminiConnection(settings: fixture.settings)

        connection.check()
        guard case .needsApproval(let proposed) = connection.phase else {
            Issue.record("Expected the Gemini hook confirmation")
            return
        }
        #expect(proposed.file == fixture.file)
        #expect(proposed.command.hasSuffix(" --agent-hold-stop-hook --provider gemini"))
        #expect(proposed.command.contains("'\\''"))
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        connection.reset()
        connection.approve()
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))

        connection.check()
        try fixture.write("""
        {
          "general": {"enableAutoUpdate": false},
          "hooksConfig": {"disabled": ["unrelated"]},
          "hooks": {
            "BeforeAgent": [{"hooks": [{"type": "command", "command": "existing-before"}]}],
            "AfterAgent": [{"matcher": "*", "sequential": true, "hooks": [{"type": "command", "command": "existing-after"}]}]
          }
        }
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.file.path)
        connection.approve()
        guard case .ready = connection.phase else {
            Issue.record("Expected the Gemini hook to be installed after confirmation")
            return
        }

        let bytes = try Data(contentsOf: fixture.file)
        let root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((root["general"] as? [String: Bool])?["enableAutoUpdate"] == false)
        #expect((root["hooksConfig"] as? [String: [String]])?["disabled"] == ["unrelated"])
        let hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
        #expect((hooks["BeforeAgent"]?.first?["hooks"] as? [[String: String]])?.first?["command"] == "existing-before")
        let afterAgent = try #require(hooks["AfterAgent"])
        #expect(afterAgent.count == 2)
        #expect(afterAgent.first?["sequential"] as? Bool == true)
        #expect((afterAgent.first?["hooks"] as? [[String: String]])?.first?["command"] == "existing-after")
        let entry = try #require((afterAgent.last?["hooks"] as? [[String: Any]])?.first)
        #expect(entry["name"] as? String == "agent-hold")
        #expect(entry["command"] as? String == proposed.command)
        #expect(entry["timeout"] as? Int == 5000)
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? Int == 0o640)
        connection.check()
        guard case .ready = connection.phase else {
            Issue.record("Expected an idempotent check")
            return
        }
        try proposed.install()
        #expect(try Data(contentsOf: fixture.file) == bytes)
    }

    @Test
    func retainsCommentsMalformedConfigurationAndDisabledHooks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connection = GeminiConnection(settings: fixture.settings)
        for contents in ["{ // keep this comment\n \"general\": {}}", "{malformed"] {
            try fixture.write(contents)
            connection.check()
            guard case .manual(let configuration) = connection.phase else {
                Issue.record("Expected a copyable manual configuration")
                continue
            }
            #expect(configuration.snippet.contains("\"AfterAgent\""))
            #expect(configuration.snippet.contains("--provider gemini"))
            connection.approve()
            #expect(try String(contentsOf: fixture.file, encoding: .utf8) == contents)
        }

        for contents in [
            "{\"hooksConfig\": {\"enabled\": false}}",
            "{\"hooksConfig\": {\"disabled\": [\"agent-hold\"]}}",
            "{\"hooksConfig\": {\"enabled\": 1}}",
            "{\"hooks\": {\"AfterAgent\": false}}",
            "{\"hooks\": {\"AfterAgent\": [{\"hooks\": [{\"name\": \"agent-hold\", \"command\": \"custom\"}]}]}}",
        ] {
            try fixture.write(contents)
            connection.check()
            guard case .failed = connection.phase else {
                Issue.record("Expected disabled, invalid, or conflicting hooks to require manual inspection")
                continue
            }
            connection.approve()
            #expect(try String(contentsOf: fixture.file, encoding: .utf8) == contents)
        }
    }

    @Test
    func recognizesAnInstalledHookInCommentedSettingsWithoutWriting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = try fixture.settings.configuration()
        try configuration.install()
        let json = try String(contentsOf: fixture.file, encoding: .utf8)
        let commented = """
        // Gemini settings
        /* Keep these comments. */
        \(json)
        """
        try fixture.write(commented)
        let connection = GeminiConnection(settings: fixture.settings)
        connection.check()
        guard case .ready = connection.phase else {
            Issue.record("Expected a manual hook in commented settings to be recognized")
            return
        }
        try configuration.install()
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == commented)
    }

    @Test
    func respectsGeminiCLIHomeAndRepairsThisAppsMovedHelper() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try GeminiConnection.geminiHome(userHome: fixture.home, environment: [:]) == fixture.home)
        #expect(throws: GeminiHookConfiguration.Failure.relativeHome) {
            try GeminiConnection.geminiHome(userHome: fixture.home, environment: ["GEMINI_CLI_HOME": "relative"])
        }
        let oldHook = fixture.home.appendingPathComponent("old location/AgentHoldHook")
        try Fixture.makeExecutable(oldHook)
        let previous = GeminiHookConfiguration(file: fixture.file, executable: oldHook)
        try previous.install()
        let current = try fixture.settings.configuration()
        #expect(try !current.isInstalled())
        try current.install()
        #expect(try current.isInstalled())
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any])
        let events = try #require(root["hooks"] as? [String: [[String: Any]]])
        let groups = try #require(events["AfterAgent"])
        #expect(groups.count == 1)
        let entries = try #require(groups.first?["hooks"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["command"] as? String == current.command)
    }

    private struct Fixture {
        let home: URL
        let hook: URL
        let cli: URL
        var file: URL { home.appendingPathComponent("override/.gemini/settings.json") }
        var settings: GeminiConnection.Settings {
            GeminiConnection.Settings(
                home: home, hook: hook, environment: ["GEMINI_CLI_HOME": home.appendingPathComponent("override").path],
                cli: cli
            )
        }

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-hold-gemini-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            hook = home.appendingPathComponent("It's here/AgentHoldHook")
            cli = home.appendingPathComponent("gemini")
            try Self.makeExecutable(hook)
            try Self.makeExecutable(cli)
        }

        static func makeExecutable(_ result: URL) throws {
            try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: result)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: result.path)
        }

        func write(_ contents: String) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}
