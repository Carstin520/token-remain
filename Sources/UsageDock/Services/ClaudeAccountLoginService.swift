import Darwin
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

    var executable: URL? = nil
    var loginTimeout: TimeInterval = AccountLoginProcessRunner.loginTimeout
    var statusTimeout: TimeInterval = AccountLoginProcessRunner.statusTimeout

    func login(configurationDirectory: URL) async throws {
        try Task.checkCancellation()
        guard let executable = executable ?? Self.claudeExecutable() else { throw LoginError.cliNotFound }
        var environment = ProviderAccountProcessEnvironment.claude(
            base: ProcessInfo.processInfo.environment,
            configurationDirectory: configurationDirectory
        )
        environment["PATH"] = ProviderCLIExecutableResolver.launchPath(
            existing: environment["PATH"], executable: executable
        )
        environment["TERM"] = "xterm-256color"
        let deadline = ProcessInfo.processInfo.systemUptime + loginTimeout
        do {
            // The official TUI needs a PTY to avoid opening OAuth twice.
            _ = try await AccountLoginProcessRunner.run(
                executable: executable, arguments: ["auth", "login", "--claudeai"],
                environment: environment, usesTerminal: true, timeout: loginTimeout
            )
            let data = try await AccountLoginProcessRunner.run(
                executable: executable, arguments: ["auth", "status", "--json"],
                environment: environment, capturesOutput: true,
                timeout: min(statusTimeout, deadline - ProcessInfo.processInfo.systemUptime)
            )
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["loggedIn"] as? Bool == true else {
                throw LoginError.loginDidNotCreateSession
            }
            try Task.checkCancellation()
        } catch AccountLoginProcessRunner.Failure.exited(let status) {
            throw LoginError.loginFailed(status)
        }
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
