import Foundation

/// Runs the official Codex login flow inside an app-owned CODEX_HOME. The
/// resulting OAuth material remains owned by Codex; TokenRemain only reads it.
struct CodexAccountLoginService: Sendable {
    enum LoginError: LocalizedError {
        case cliNotFound
        case loginFailed(Int32)
        case loginDidNotCreateSession

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                "Codex CLI was not found. Install Codex, then try again."
            case .loginFailed:
                "Codex account sign-in did not complete."
            case .loginDidNotCreateSession:
                "Codex finished without creating a signed-in profile."
            }
        }
    }

    var executableURL: URL? = nil
    var loginTimeout: TimeInterval = AccountLoginProcessRunner.loginTimeout
    var statusTimeout: TimeInterval = AccountLoginProcessRunner.statusTimeout

    func login(configurationDirectory: URL) async throws {
        try Task.checkCancellation()
        guard let executable = executableURL ?? Self.executable() else { throw LoginError.cliNotFound }
        var environment = ProviderAccountProcessEnvironment.codex(
            base: ProcessInfo.processInfo.environment,
            configurationDirectory: configurationDirectory
        )
        // Keep Node resolvable for CLI installations outside a GUI app's PATH.
        environment["PATH"] = ProviderCLIExecutableResolver.launchPath(
            existing: environment["PATH"], executable: executable
        )
        let deadline = ProcessInfo.processInfo.systemUptime + loginTimeout
        do {
            _ = try await AccountLoginProcessRunner.run(
                executable: executable, arguments: ["login"], environment: environment,
                timeout: loginTimeout
            )
            let data = try await AccountLoginProcessRunner.run(
                executable: executable, arguments: ["login", "status"], environment: environment,
                capturesOutput: true, mergesStandardError: true,
                timeout: min(statusTimeout, deadline - ProcessInfo.processInfo.systemUptime)
            )
            let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            guard text.contains("logged in") else { throw LoginError.loginDidNotCreateSession }
            try Task.checkCancellation()
        } catch AccountLoginProcessRunner.Failure.exited(let status) {
            throw LoginError.loginFailed(status)
        }
    }

    static func executable(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        ProviderCLIExecutableResolver.resolve(
            named: "codex",
            appBundleName: "Codex",
            homeDirectory: homeDirectory,
            environment: environment
        )
    }
}
