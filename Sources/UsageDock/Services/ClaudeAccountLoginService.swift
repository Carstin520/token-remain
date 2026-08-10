import Foundation

struct ClaudeAccountLoginService: Sendable {
    enum LoginError: LocalizedError {
        case cliNotFound
        case loginFailed(Int32)
        case loginDidNotCreateSession

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                L10n.text("service.claude.cli_not_found")
            case .loginFailed:
                L10n.text("service.claude.account_login_failed")
            case .loginDidNotCreateSession:
                L10n.text("service.claude.account_session_missing")
            }
        }
    }

    func login(configurationDirectory: URL) async throws {
        try await run(
            arguments: ["auth", "login", "--claudeai"],
            configurationDirectory: configurationDirectory
        )
        let status = try await status(configurationDirectory: configurationDirectory)
        guard status else { throw LoginError.loginDidNotCreateSession }
    }

    private func status(configurationDirectory: URL) async throws -> Bool {
        let data = try await run(
            arguments: ["auth", "status", "--json"],
            configurationDirectory: configurationDirectory,
            capturesOutput: true
        )
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["loggedIn"] as? Bool == true
    }

    @discardableResult
    private func run(
        arguments: [String],
        configurationDirectory: URL,
        capturesOutput: Bool = false
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let executable = Self.claudeExecutable() else {
                throw LoginError.cliNotFound
            }
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CONFIG_DIR"] = configurationDirectory.path
            environment["PATH"] = Self.pathWithClaudeHints(environment["PATH"])
            process.environment = environment
            if capturesOutput {
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
            } else {
                // Claude opens the OAuth page itself. Keep terminal chatter out of
                // the GUI process while the browser completes the official flow.
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
            }
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw LoginError.loginFailed(process.terminationStatus)
            }
            return capturesOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        }.value
    }

    private static func claudeExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/claude" }
        }
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private static func pathWithClaudeHints(_ existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hints = [
            "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ]
        let current = existing?.split(separator: ":").map(String.init) ?? []
        return Array(NSOrderedSet(array: hints + current))
            .compactMap { $0 as? String }
            .joined(separator: ":")
    }
}
