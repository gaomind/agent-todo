import Foundation
import Testing
@testable import AgentHold

@MainActor
struct CodexLiveProbeTests {
    @Test(arguments: [false, true])
    func aSuccessfulCLIStillRequiresTheMatchingStopReceipt(sendWrongThread: Bool) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }

        let cwdFile = temp.appendingPathComponent("cwd")
        let releaseFile = temp.appendingPathComponent("release")
        let cli = temp.appendingPathComponent("codex")
        let session = UUID()
        try """
        #!/bin/sh
        printf '%s' "$PWD" > "$CODEX_HOME/cwd"
        while [ ! -f "$CODEX_HOME/release" ]; do /bin/sleep 0.02; done
        printf '%s\\n' '{"type":"thread.started","thread_id":"\(session.uuidString)"}'

        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        let probe = CodexLiveProbe(timeout: .seconds(4), receiptTimeout: .milliseconds(250), codexHome: temp)
        probe.start(cli: cli)
        defer { probe.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        var cwd = ""
        while cwd.isEmpty {
            try #require(clock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
            cwd = (try? String(contentsOf: cwdFile, encoding: .utf8)) ?? ""
        }
        let workspace = URL(fileURLWithPath: cwd, isDirectory: true)
        let token = String(workspace.lastPathComponent.suffix(36))
        try #require(UUID(uuidString: token) != nil)
        if sendWrongThread {
            let reply = CodexReply(sessionID: UUID().uuidString, cwd: cwd,
                                   message: "恢复条件：等待连接测试确认 \(token) 后继续。", receivedAt: Date())
            #expect(probe.accept(reply, conditions: HoldDetector.conditions(in: reply.message)))
        }

        try Data().write(to: releaseFile)
        while case .running = probe.state {
            try #require(clock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case let .failed(message) = probe.state else {
            Issue.record("CLI exit without the matching Stop receipt must fail.")
            return
        }
        #expect(message.contains(sendWrongThread ? "不匹配" : "未收到"))
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }
}
