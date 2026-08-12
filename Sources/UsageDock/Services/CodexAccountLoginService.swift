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

    func login(configurationDirectory: URL) async throws {
        try await run(arguments: ["login"], configurationDirectory: configurationDirectory)
        let data = try await run(
            arguments: ["login", "status"],
            configurationDirectory: configurationDirectory,
            capturesOutput: true
        )
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        guard text.contains("logged in") else {
            throw LoginError.loginDidNotCreateSession
        }
    }

    @discardableResult
    private func run(
        arguments: [String],
        configurationDirectory: URL,
        capturesOutput: Bool = false
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let executable = Self.executable() else {
                throw LoginError.cliNotFound
            }
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProviderAccountProcessEnvironment.codex(
                base: ProcessInfo.processInfo.environment,
                configurationDirectory: configurationDirectory
            )
            // GUI apps do not inherit the user's interactive shell PATH. Keep
            // the resolved CLI's directory first so Node-based Codex installs
            // (for example NVM) can also resolve their `node` interpreter.
            environment["PATH"] = ProviderCLIExecutableResolver.launchPath(
                existing: environment["PATH"],
                executable: executable
            )
            process.environment = environment
            if capturesOutput {
                process.standardOutput = output
                process.standardError = output
            } else {
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
