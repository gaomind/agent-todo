import Foundation
import Testing
@testable import AgentHold

struct ProviderCLITests {
    @Test
    func findsGlobalNpmInstallUnderNVMWithoutShellPath() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let version = home.appendingPathComponent(".nvm/versions/node/v22.23.1")
        let cli = version.appendingPathComponent("bin/claude")
        let script = version.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code/cli.js")
        try makeExecutable(script)
        try makeExecutable(version.appendingPathComponent("bin/node"))
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: script)
        #expect(ProviderCLI.find("claude", home: home, environment: [:]) == cli)

        let userBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        let linkedCLI = userBin.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: linkedCLI, withDestinationURL: script)
        #expect(ProviderCLI.find("claude", home: home, environment: [:]) == linkedCLI)
        let environment = ProviderCLI.launchEnvironment(for: linkedCLI, environment: ["PATH": ".:/usr/bin:/bin"])
        #expect(environment["PATH"]?.split(separator: ":").prefix(3).map(String.init) == [
            userBin.path, version.appendingPathComponent("bin").path, "/usr/bin",
        ])
    }

    private func makeExecutable(_ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
}
