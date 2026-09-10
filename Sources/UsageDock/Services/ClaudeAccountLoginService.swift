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

    func login(configurationDirectory: URL) async throws {
        try await runLogin(configurationDirectory: configurationDirectory)
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

    /// `claude auth login` is a TUI. Pointing stdout/stderr at `/dev/null`
    /// makes Ink think the first browser open failed, so it launches OAuth
    /// a second time. Give it a real PTY, drain the paint, and wait for the
    /// official callback to finish.
    private func runLogin(configurationDirectory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let executable = Self.claudeExecutable() else {
                throw LoginError.cliNotFound
            }

            var master: Int32 = -1
            var slave: Int32 = -1
            var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
                throw LoginError.loginFailed(-1)
            }
            defer { Darwin.close(master) }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["auth", "login", "--claudeai"]
            var environment = ProviderAccountProcessEnvironment.claude(
                base: ProcessInfo.processInfo.environment,
                configurationDirectory: configurationDirectory
            )
            environment["PATH"] = ProviderCLIExecutableResolver.launchPath(
                existing: environment["PATH"],
                executable: executable
            )
            environment["TERM"] = "xterm-256color"
            process.environment = environment

            let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            process.standardInput = terminal
            process.standardOutput = terminal
            process.standardError = terminal
            try process.run()
            Darwin.close(slave)

            let flags = fcntl(master, F_GETFL)
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
            var bytes = [UInt8](repeating: 0, count: 8_192)
            while process.isRunning {
                while Darwin.read(master, &bytes, bytes.count) > 0 {}
                usleep(50_000)
            }
            process.waitUntilExit()
            while Darwin.read(master, &bytes, bytes.count) > 0 {}
            guard process.terminationStatus == 0 else {
                throw LoginError.loginFailed(process.terminationStatus)
            }
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
