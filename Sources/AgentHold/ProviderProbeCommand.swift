import Foundation

struct ProviderProbeCommand {
    let provider: HoldProvider
    let arguments: [String]
    let environment: [String: String]
    let expectedSession: UUID?

    static func make(
        provider: HoldProvider, cli: URL, workspace: URL, prompt: String,
        environment: [String: String], codexHome: URL, configuration: URL? = nil
    ) throws -> Self {
        var environment = ProviderCLI.launchEnvironment(for: cli, environment: environment)
        let session = provider == .codex ? nil : UUID()
        let sessionArgument = session?.uuidString.lowercased() ?? ""
        let arguments: [String]
        switch provider {
        case .codex:
            environment["CODEX_HOME"] = codexHome.path
            arguments = [
                "exec", "--cd", workspace.path, "--skip-git-repo-check", "--ephemeral",
                "--json", "--color", "never", "--sandbox", "read-only",
                "--disable", "shell_tool", "--disable", "unified_exec",
                "--disable", "apps", "--disable", "plugins", "--disable", "code_mode",
                "--disable", "image_generation", "--disable", "multi_agent_v2",
                "--disable", "computer_use", "--disable", "browser_use", "--disable", "browser_use_external",
                "-c", "approval_policy=never", "-c", "web_search=disabled",
                "-c", "project_doc_max_bytes=0", "-c", "notify=[]",
                "--", prompt,
            ]
        case .claude:
            if let configuration { environment["CLAUDE_CONFIG_DIR"] = configuration.deletingLastPathComponent().path }
            environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            environment["CLAUDE_CODE_MAX_RETRIES"] = "0"
            environment.removeValue(forKey: "CLAUDECODE")
            arguments = [
                "--print", "--output-format", "json", "--session-id", sessionArgument,
                "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                "--mcp-config", #"{"mcpServers":{}}"#, "--permission-mode", "dontAsk",
                "--permission-prompts", "none", "--setting-sources", "user", "--", prompt,
            ]
        case .grok:
            if let configuration {
                environment["GROK_HOME"] = configuration.deletingLastPathComponent().deletingLastPathComponent().path
            }
            // Turn summaries and workflow discovery add work to an otherwise isolated single turn.
            environment["GROK_TURN_SUMMARY"] = "false"
            environment["GROK_WORKFLOWS"] = "false"
            environment["GROK_MEMORY"] = "false"
            arguments = [
                "--cwd", workspace.path, "--session-id", sessionArgument,
                "--output-format", "json", "--permission-mode", "dontAsk", "--deny", "*",
                "--disable-web-search", "--no-subagents", "--no-plan", "--verbatim", "--max-turns", "1",
                // An empty --tools value keeps the defaults. Restrict the allowlist first,
                // then remove that tool and the two always-available tool routers.
                "--tools", "read_file", "--disallowed-tools", "read_file,search_tool,use_tool",
                "--single", prompt,
            ]
        case .gemini:
            if let configuration {
                // The connection retains the logical .gemini directory even when it is a symlink.
                environment["GEMINI_CLI_HOME"] = configuration.deletingLastPathComponent().deletingLastPathComponent().path
            }
            let policy = workspace.appendingPathComponent("agent-hold-policy.toml")
            try Data("""
                [[rule]]
                toolName = "*"
                decision = "deny"
                priority = 999
                """.utf8).write(to: policy, options: .withoutOverwriting)
            arguments = [
                "--skip-trust", "--session-id", sessionArgument, "--output-format", "stream-json",
                "--approval-mode", "plan", "--policy", policy.path,
                "--extensions", "none", "--allowed-mcp-server-names", "agent-hold-probe-\(sessionArgument)",
                "--prompt", prompt,
            ]
        case .unknown:
            throw CocoaError(.featureUnsupported)
        }

        return Self(provider: provider, arguments: arguments, environment: environment, expectedSession: session)
    }

    func sessionID(inOutputLine line: Data) -> UUID? {
        guard let object = object(in: line), let type = object["type"] as? String else { return nil }
        let key: String
        switch (provider, type) {
        case (.codex, "thread.started"): key = "thread_id"
        case (.claude, "result"), (.gemini, "init"): key = "session_id"
        case (.claude, "system") where object["subtype"] as? String == "init": key = "session_id"
        default: return nil
        }
        return (object[key] as? String).flatMap(UUID.init(uuidString:))
    }

    func sessionID(inFinalOutput output: Data) -> UUID? {
        switch provider {
        case .grok:
            return (object(in: output)?["sessionId"] as? String).flatMap(UUID.init(uuidString:))
        default:
            return sessionID(inOutputLine: output)
        }
    }

    func isAuthenticationError(_ data: Data, isOutput: Bool) -> Bool {
        if isOutput {
            guard let event = object(in: data), let type = event["type"] as? String else { return false }
            let failed = type == "error" || type == "turn.failed" || event["is_error"] as? Bool == true
                || (type == "result" && event["status"] as? String == "error")
            guard failed else { return false }
            if event["api_error_status"] as? Int == 401 { return true }
        }
        let message = String(decoding: data, as: UTF8.self).lowercased()
        let common = ["401 unauthorized", "invalid_api_key", "not logged in", "authentication required", "missing bearer"]
        let additional: [String]
        switch provider {
        case .codex: additional = ["codex login"]
        case .claude: additional = ["please run /login", "invalid api key", "authentication_error", "oauth token has expired"]
        case .grok: additional = ["grok login", "no authentication credentials", "no credentials found", "invalid api key"]
        case .gemini: additional = ["please set an auth method", "gemini_api_key", "unauthenticated", "invalid api key", "login required"]
        case .unknown: additional = []
        }
        return (common + additional).contains(where: message.contains)
    }

    private func object(in data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
