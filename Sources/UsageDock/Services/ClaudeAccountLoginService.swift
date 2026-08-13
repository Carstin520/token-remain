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
            var environment = ProviderAccountProcessEnvironment.claude(
                base: ProcessInfo.processInfo.environment,
                configurationDirectory: configurationDirectory
            )
            environment["PATH"] = ProviderCLIExecutableResolver.launchPath(
                existing: environment["PATH"],
                executable: executable
            )
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

    static func claudeExecutable(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        ProviderCLIExecutableResolver.resolve(
            named: "claude",
            homeDirectory: homeDirectory,
            environment: environment
        )
    }
}
