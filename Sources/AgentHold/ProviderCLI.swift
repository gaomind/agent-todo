import Foundation

enum ProviderCLI {
    static func find(
        _ name: String,
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        extra: [URL] = []
    ) -> URL? {
        func absoluteDirectory(_ path: String?) -> URL? {
            guard let path, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        let path = (environment["PATH"] ?? "").split(separator: ":").compactMap {
            absoluteDirectory(String($0))
        }
        let npmPrefix = absoluteDirectory(environment["npm_config_prefix"] ?? environment["NPM_CONFIG_PREFIX"])
        let usual = [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".asdf/shims"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
        ]
        let directories = extra + path + [npmPrefix?.appendingPathComponent("bin")].compactMap { $0 } + usual
        if let installed = executable(name, in: directories) { return installed }

        let nvm = absoluteDirectory(environment["NVM_DIR"]) ?? home.appendingPathComponent(".nvm", isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: nvm.appendingPathComponent("versions/node", isDirectory: true),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let nvmBins = versions.filter { $0.lastPathComponent.hasPrefix("v") }.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }.map { $0.appendingPathComponent("bin", isDirectory: true) }
        return executable(name, in: nvmBins)
    }

    static func launchEnvironment(for cli: URL, environment: [String: String]) -> [String: String] {
        var environment = environment
        // The launch URL retains the npm-installed shim path so /usr/bin/env
        // can resolve the Node executable in the same nvm bin directory.
        let sibling = cli.deletingLastPathComponent().path
        let npmBin = npmBinDirectory(for: cli)?.path
        let inherited = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let directories = [sibling, npmBin].compactMap { $0 } + inherited.map(String.init) + system
        var seen = Set<String>()
        environment["PATH"] = directories.filter { seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    private static func npmBinDirectory(for cli: URL) -> URL? {
        var directory = cli.resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            let parent = directory.deletingLastPathComponent()
            if directory.lastPathComponent == "node_modules", parent.lastPathComponent == "lib" {
                let bin = parent.deletingLastPathComponent().appendingPathComponent("bin", isDirectory: true)
                return executable("node", in: [bin]) == nil ? nil : bin
            }
            directory = parent
        }
        return nil
    }

    private static func executable(_ name: String, in directories: [URL]) -> URL? {
        directories.lazy.map { $0.appendingPathComponent(name).standardizedFileURL }
            .first(where: ClaudeHookConfiguration.isExecutable)
    }
}
