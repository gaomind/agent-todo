import Foundation
import Testing
@testable import AgentHold

struct ProviderProbeCommandTests {
    @Test
    func distinguishesAuthenticationErrorsFromModelOutput() {
        let claude = command(.claude)
        let grok = command(.grok)
        let gemini = command(.gemini)
        #expect(claude.isAuthenticationError(Data(#"{"type":"result","is_error":true,"api_error_status":401}"#.utf8), isOutput: true))
        #expect(grok.isAuthenticationError(Data(#"{"type":"error","message":"Not signed in. Run grok login --device-code"}"#.utf8), isOutput: true))
        #expect(gemini.isAuthenticationError(Data("Please set an Auth method in settings.json".utf8), isOutput: false))
        #expect(!gemini.isAuthenticationError(Data(#"{"type":"message","role":"assistant","content":"Authentication required"}"#.utf8), isOutput: true))
        #expect(!claude.isAuthenticationError(Data(#"{"type":"result","is_error":false,"result":"Please run /login"}"#.utf8), isOutput: true))
    }

    private func command(_ provider: HoldProvider) -> ProviderProbeCommand {
        ProviderProbeCommand(provider: provider, arguments: [], environment: [:], expectedSession: nil)
    }
}
