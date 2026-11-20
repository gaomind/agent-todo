import Foundation
import Testing
@testable import AgentHold

@MainActor
struct ProviderLiveProbeTests {
    @Test(arguments: [HoldProvider.codex, .claude, .grok, .gemini])
    func succeedsOnlyWithAnIsolatedReceiptAndPreservesOtherStates(provider: HoldProvider) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeCLI(provider: provider)
        let probe = fixture.makeProbe()
        let other: HoldProvider = provider == .codex ? .claude : .codex
        probe.start(provider: provider, cli: fixture.cli)
        probe.start(provider: other, cli: fixture.cli)
        #expect(probe.activeProvider == provider)
        guard case .idle = probe.state(for: other) else {
            Issue.record("A second provider cannot start while another probe is running.")
            await probe.cancelAndWait()
            return
        }

        let workspace = try await fixture.waitForWorkspace()
        let session = try fixture.session()
        #expect(probe.accept(fixture.reply(provider: other, session: session, workspace: workspace),
                             conditions: [fixture.condition(in: workspace)]))
        #expect(probe.accept(fixture.reply(provider: provider, session: session, workspace: workspace,
                                          body: "恢复条件：收到用户批准后继续"),
                             conditions: ["收到用户批准后继续"]))
        #expect(!probe.accept(fixture.reply(provider: provider, session: session, workspace: workspace,
                                           cwd: fixture.directory.path),
                              conditions: [fixture.condition(in: workspace)]))
        try fixture.release()
        try await waitUntil { probe.activeProvider == nil }
        guard case let .failed(failure) = probe.state(for: provider) else {
            Issue.record("Incorrect provider, missing marker, and wrong workspace must all fail.")
            return
        }
        #expect(failure.contains("缺少预期"))
        #expect(!FileManager.default.fileExists(atPath: workspace.path))

        try fixture.reset()
        probe.start(provider: provider, cli: fixture.cli)
        let retryWorkspace = try await fixture.waitForWorkspace()
        let retrySession = try fixture.session()
        #expect(workspace != retryWorkspace)
        #expect(probe.accept(fixture.reply(provider: provider, session: retrySession, workspace: workspace),
                             conditions: [fixture.condition(in: workspace)]))
        let receipt = fixture.reply(provider: provider, session: retrySession, workspace: retryWorkspace)
        #expect(probe.accept(receipt, conditions: receipt.detectedConditions))
        try fixture.release()
        try await waitUntil { probe.activeProvider == nil }
        guard case .passed = probe.state(for: provider) else {
            Issue.record("The matching provider, workspace, marker, and session must pass.")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: retryWorkspace.path))
    }

    @Test(arguments: [HoldProvider.claude, .grok, .gemini])
    func aConflictingCLIReportedSessionCannotPass(provider: HoldProvider) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeCLI(provider: provider, contradictorySession: UUID())
        let probe = fixture.makeProbe()
        probe.start(provider: provider, cli: fixture.cli)
        let workspace = try await fixture.waitForWorkspace()
        let session = try fixture.session()
        let receipt = fixture.reply(provider: provider, session: session, workspace: workspace)
        #expect(probe.accept(receipt, conditions: receipt.detectedConditions))
        try fixture.release()
        try await waitUntil { probe.activeProvider == nil }
        guard case .failed = probe.state(for: provider) else {
            Issue.record("The CLI reported a different identity from its requested or received session.")
            return
        }
    }

    @Test(arguments: [false, true])
    func stoppingReapsTheCLIAndKeepsLateRepliesOutOfTheInbox(timeOut: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeCLI(provider: .claude)
        let probe = fixture.makeProbe(timeout: timeOut ? .milliseconds(700) : .seconds(4))
        probe.start(provider: .claude, cli: fixture.cli)
        let workspace = try await fixture.waitForWorkspace()
        let session = try fixture.session()
        if timeOut {
            try await waitUntil { probe.activeProvider == nil }
            guard case let .failed(message) = probe.state(for: .claude) else {
                Issue.record("Expected the stalled CLI to time out.")
                return
            }
            #expect(message.contains("超时"))
        } else {
            await probe.cancelAndWait()
            guard case .cancelled = probe.state(for: .claude) else {
                Issue.record("Expected cancellation.")
                return
            }
        }
        #expect(probe.activeProvider == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        let receipt = fixture.reply(provider: .claude, session: session, workspace: workspace,
                                    body: "恢复条件：收到用户批准后继续")
        #expect(probe.accept(receipt, conditions: receipt.detectedConditions))
    }

    @MainActor

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexSession = UUID()
        var cli: URL { directory.appendingPathComponent("probe-cli") }
        var cwd: URL { directory.appendingPathComponent("cwd") }
        var sessionFile: URL { directory.appendingPathComponent("session") }
        var releaseFile: URL { directory.appendingPathComponent("release") }

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func makeProbe(timeout: Duration = .seconds(4)) -> CodexLiveProbe {
            CodexLiveProbe(timeout: timeout, receiptTimeout: .milliseconds(200), codexHome: directory)
        }

        func writeCLI(provider: HoldProvider, contradictorySession: UUID? = nil) throws {
            let sessionKey = provider == .codex ? "thread_id" : "session_id"
            let event = switch provider {
            case .codex: "thread.started"
            case .gemini: "init"
            default: "result"
            }
            let reported = contradictorySession?.uuidString ?? "$session"
            let output = provider == .grok
                ? "printf '{\\n  \"stopReason\": \"end_turn\",\\n  \"sessionId\": \"%s\"\\n}' \"\(reported)\""
                : "printf '%s' \"{\\\"type\\\":\\\"\(event)\\\",\\\"\(sessionKey)\\\":\\\"\(reported)\\\"}\""
            try """
            #!/bin/sh
            session='\(provider == .codex ? codexSession.uuidString : "")'
            while [ "$#" -gt 0 ]; do
                if [ "$1" = --session-id ]; then session="$2"; break; fi
                shift
            done
            printf '%s' "$session" > \(CodexHookConfiguration.shellQuote(sessionFile.path))
            printf '%s' "$PWD" > \(CodexHookConfiguration.shellQuote(cwd.path))
            while [ ! -f \(CodexHookConfiguration.shellQuote(releaseFile.path)) ]; do /bin/sleep 0.02; done
            \(output)

            """.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }

        func waitForWorkspace() async throws -> URL {
            try await waitUntil {
                guard let path = try? String(contentsOf: cwd, encoding: .utf8) else { return false }
                return !path.isEmpty
            }
            return URL(fileURLWithPath: try String(contentsOf: cwd, encoding: .utf8), isDirectory: true)
        }

        func session() throws -> UUID {
            try #require(UUID(uuidString: String(contentsOf: sessionFile, encoding: .utf8)))
        }

        func release() throws { try Data().write(to: releaseFile) }

        func reset() throws {
            for file in [cwd, sessionFile, releaseFile] { try FileManager.default.removeItem(at: file) }
        }

        func condition(in workspace: URL) -> String {
            "等待连接测试确认 \(workspace.lastPathComponent.suffix(36)) 后继续"
        }

        func reply(provider: HoldProvider, session: UUID, workspace: URL, cwd: String? = nil,
                   body: String? = nil) -> CodexReply {
            CodexReply(sessionID: session.uuidString, cwd: cwd ?? workspace.path,
                       message: body ?? "恢复条件：\(condition(in: workspace))。", receivedAt: Date(), provider: provider)
        }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    while !condition() {
        try #require(clock.now < deadline)
        try await Task.sleep(for: .milliseconds(20))
    }
}
