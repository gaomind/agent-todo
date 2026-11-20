import Darwin
import Foundation
import Testing
@testable import AgentHold

@MainActor
struct CodexConnectionTests {
    @Test
    func wedgedAppServerTimesOutAndIsReaped() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHoldConnection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("codex")
        try "#!/bin/sh\nprintf '%s' \"$$\" > server.pid\nexec /bin/sleep 60\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let connection = CodexConnection(settings: .init(
            home: folder, codexHome: folder, hook: URL(fileURLWithPath: "/usr/bin/true"),
            cli: cli, timeout: .milliseconds(300)
        ))
        connection.prepare()
        guard case let .failed(message) = try await settled(connection) else {
            Issue.record("Expected the unresponsive app-server to fail")
            return
        }
        #expect(message.contains("启动和握手时超时"))
        let pid = try #require(Int32(String(contentsOf: folder.appendingPathComponent("server.pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_HOLD_TEST_CODEX"] != nil))
    func testInstalledCLIOnlyTrustsTheConfirmedHook() async throws {
        let cli = try installedCLI()
        let fixture = try Fixture(cli: cli)
        defer { fixture.remove() }

        // Keep an unrelated state entry in place when the selected hook is trusted.
        let config = fixture.home.appendingPathComponent("config.toml")
        let sqliteHome = fixture.home.appendingPathComponent("custom-state")
        try """
        sqlite_home = "\(sqliteHome.path)"

        [hooks.state."unrelated"]
        enabled = false
        """.write(to: config, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: config)
        let connection = CodexConnection(settings: fixture.settings)

        connection.prepare()
        guard case let .needsApproval(review) = try await settled(connection) else {
            Issue.record("Expected a review from the installed Codex CLI")
            return
        }
        #expect(review.command == "exec '/usr/bin/true' --agent-hold-stop-hook")
        #expect(URL(fileURLWithPath: review.sourcePath).resolvingSymlinksInPath().path
            == fixture.home.appendingPathComponent("hooks.json").resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: config) == original)
        let stateFiles = try databaseFiles(in: sqliteHome)
        #expect(!stateFiles.isEmpty)

        connection.reset()
        #expect(try Data(contentsOf: config) == original)
        connection.prepare()
        guard case .needsApproval = try await settled(connection) else {
            Issue.record("Expected the cancelled review to remain untrusted")
            return
        }
        connection.approve()
        guard case .ready = try await settled(connection) else {
            Issue.record("Expected Codex CLI to confirm persisted trust")
            return
        }
        let saved = try String(contentsOf: config, encoding: .utf8)
        #expect(saved.contains("trusted_hash"))
        #expect(saved.contains("unrelated"))
        #expect(saved.contains("enabled = false"))

        let reopened = CodexConnection(settings: fixture.settings)
        reopened.prepare()
        guard case .ready = try await settled(reopened) else {
            Issue.record("Expected the next connection to detect persisted trust")
            return
        }
        #expect(try databaseFiles(in: sqliteHome) == stateFiles)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_HOLD_TEST_CODEX"] != nil))
    func testInstalledCLIRequiresReviewAgainIfDefinitionChanges() async throws {
        let fixture = try Fixture(cli: installedCLI())
        defer { fixture.remove() }
        let connection = CodexConnection(settings: fixture.settings)
        connection.prepare()
        guard case .needsApproval = try await settled(connection) else {
            Issue.record("Expected the initial review")
            return
        }

        let hooks = fixture.home.appendingPathComponent("hooks.json")
        var definition = try String(contentsOf: hooks, encoding: .utf8)
        definition = definition.replacingOccurrences(of: "\"timeout\" : 5", with: "\"timeout\" : 7")
        #expect(definition.contains("\"timeout\" : 7"))
        try definition.write(to: hooks, atomically: true, encoding: .utf8)

        connection.approve()
        guard case let .failed(message) = try await settled(connection) else {
            Issue.record("Expected the stale approval to fail")
            return
        }
        #expect(message.contains("发生变化"))
        let config = fixture.home.appendingPathComponent("config.toml")
        let data = try? String(contentsOf: config, encoding: .utf8)
        #expect(data?.contains("trusted_hash") != true)
    }

    private func installedCLI() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["AGENT_HOLD_TEST_CODEX"])
        return URL(fileURLWithPath: path)
    }

    private func databaseFiles(in folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".sqlite") })
    }

    private func settled(_ connection: CodexConnection) async throws -> CodexConnection.Phase {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        while case .checking = connection.phase, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return connection.phase
    }

    private struct Fixture {
        let home: URL
        let settings: CodexConnection.Settings

        init(cli: URL) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHoldConnection-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            settings = CodexConnection.Settings(
                home: home, codexHome: home, hook: URL(fileURLWithPath: "/usr/bin/true"), cli: cli
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: home)
        }
    }
}
