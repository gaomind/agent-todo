import Foundation
import Testing
@testable import AgentHold

struct ProviderProbeCommandTests {
    @Test
    func distinguishesAuthenticationErrorsFromModelOutput() {
        let claude = command(.claude)
        let grok = command(.grok)
        #expect(claude.isAuthenticationError(Data(#"{"type":"result","is_error":true,"api_error_status":401}"#.utf8), isOutput: true))
        #expect(grok.isAuthenticationError(Data(#"{"type":"error","message":"Not signed in. Run grok login --device-code"}"#.utf8), isOutput: true))
        #expect(!claude.isAuthenticationError(Data(#"{"type":"result","is_error":false,"result":"Please run /login"}"#.utf8), isOutput: true))
    }

    @Test
    func antigravityUsesRunOnlyPolicyAndParsesNestedResult() throws {
        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        let probe = try ProviderProbeCommand.make(
            provider: .antigravity, cli: home.appendingPathComponent("bin/agy"),
            workspace: home.appendingPathComponent("work"), prompt: "probe",
            environment: [:], codexHome: home,
            configuration: home.appendingPathComponent(".gemini/config/hooks.json")
        )
        #expect(probe.environment["HOME"] == home.path)
        #expect(probe.expectedSession == nil)
        #expect(probe.arguments.suffix(4) == ["--output-format", "stream-json", "--print", "probe"])
        #expect(probe.arguments[1].contains("mcp(*)"))
        let id = UUID()
        let initLine = Data("""
            {"event":"init","conversation_id":"\(id)"}
            """.utf8)
        let success = Data("""
            {"event":"result","result":{"conversation_id":"\(id)","status":"SUCCESS","response":"authentication required"}}
            """.utf8)
        #expect(probe.sessionID(inOutputLine: initLine) == id)
        #expect(probe.completedAntigravityReply(in: success)?.session == id)
        #expect(!probe.isAuthenticationError(success, isOutput: true))
        #expect(probe.isAuthenticationError(Data(#"{"event":"result","result":{"status":"ERROR","error":"Authentication required"}}"#.utf8), isOutput: true))
    }

    private func command(_ provider: HoldProvider) -> ProviderProbeCommand {
        ProviderProbeCommand(provider: provider, arguments: [], environment: [:], expectedSession: nil)
    }
}
