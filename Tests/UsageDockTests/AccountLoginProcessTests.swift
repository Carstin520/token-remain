import Darwin
import Foundation
import Testing
@testable import UsageDock

@Suite("Account login process lifecycle", .serialized)
struct AccountLoginProcessTests {
    @Test("Claude login has a terminal and verifies the isolated session")
    func successfulLogin() async throws {
        let fixture = try Fixture(login: "[ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 99")
        defer { fixture.remove() }
        try await fixture.claude().login(configurationDirectory: fixture.root)
    }

    @Test("Large terminal output drains without delaying completion")
    func largeTerminalOutput() async throws {
        let fixture = try Fixture(login: "/usr/bin/head -c 2097152 /dev/zero")
        defer { fixture.remove() }
        let start = Date()
        try await fixture.claude().login(configurationDirectory: fixture.root)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("Nonzero exits and missing sessions remain distinct", arguments: ["nonzero", "signedout", "invalid"])
    func failedLogin(scenario: String) async throws {
        let fixture = try Fixture(
            login: scenario == "nonzero" ? "exit 23" : ":",
            status: scenario == "signedout" ? "printf '{\"loggedIn\":false}'" : "printf 'invalid'"
        )
        defer { fixture.remove() }
        do {
            try await fixture.claude().login(configurationDirectory: fixture.root)
            Issue.record("Failed login must not succeed")
        } catch let error as ClaudeAccountLoginService.LoginError {
            switch error {
            case .loginFailed(let code): #expect(scenario == "nonzero" && code == 23)
            case .loginDidNotCreateSession: #expect(scenario != "nonzero")
            default: Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Timeout kills a login that ignores SIGTERM")
    func loginTimeout() async throws {
        let fixture = try Fixture(login: "echo $$ > \"$CLAUDE_CONFIG_DIR/pid\"\ntrap '' TERM\nexec /bin/sleep 20")
        defer { fixture.remove() }
        let start = Date()
        await expectTimeout { try await fixture.claude(timeout: 0.15).login(configurationDirectory: fixture.root) }
        #expect(Date().timeIntervalSince(start) < 2)
        try fixture.expectChildStopped()
    }

    @Test("Session verification has its own short deadline")
    func statusTimeout() async throws {
        let fixture = try Fixture(status: "echo $$ > \"$CLAUDE_CONFIG_DIR/pid\"\nexec /bin/sleep 20")
        defer { fixture.remove() }
        await expectTimeout { try await fixture.claude(statusTimeout: 0.1).login(configurationDirectory: fixture.root) }
        try fixture.expectChildStopped()
    }

    @Test("Cancelling an active login propagates to the child process")
    func cancellation() async throws {
        let fixture = try Fixture(login: "echo $$ > \"$CLAUDE_CONFIG_DIR/pid\"\ntrap '' TERM\nexec /bin/sleep 20")
        defer { fixture.remove() }
        let task = Task { try await fixture.claude().login(configurationDirectory: fixture.root) }
        defer { task.cancel() }
        try await fixture.waitForPID()
        let start = Date()
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled login must throw")
        } catch is CancellationError {}
        #expect(Date().timeIntervalSince(start) < 2)
        try fixture.expectChildStopped()
    }

    @Test("An already cancelled caller never starts login")
    func cancelledBeforeLaunch() async throws {
        let fixture = try Fixture(login: "echo $$ > \"$CLAUDE_CONFIG_DIR/pid\"")
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.claude().login(configurationDirectory: fixture.root)
        }
        do {
            try await task.value
            Issue.record("Cancelled login must throw")
        } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: fixture.pidFile.path))
    }

    @Test("Externally terminated login returns instead of spinning")
    func externalTermination() async throws {
        let fixture = try Fixture(login: "echo $$ > \"$CLAUDE_CONFIG_DIR/pid\"\nexec /bin/sleep 20")
        defer { fixture.remove() }
        let task = Task { try await fixture.claude().login(configurationDirectory: fixture.root) }
        defer { task.cancel() }
        try await fixture.waitForPID()
        let pid = try fixture.pid()
        #expect(Darwin.kill(pid, SIGTERM) == 0)
        do {
            try await task.value
            Issue.record("Terminated login must fail")
        } catch ClaudeAccountLoginService.LoginError.loginFailed {}
        try fixture.expectChildStopped()
    }

    @Test("Repeated launch failures close both terminal descriptors")
    func failedLaunchDescriptors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.claude().login(configurationDirectory: fixture.root)
        try "#!/nonexistent-tokenremain-test-interpreter\n".write(to: fixture.executable, atomically: true, encoding: .utf8)
        // Warm up Foundation's launch-error path before measuring descriptor ownership.
        _ = try? await fixture.claude().login(configurationDirectory: fixture.root)
        let before = openDescriptors()
        for _ in 0..<8 {
            do {
                try await fixture.claude().login(configurationDirectory: fixture.root)
                Issue.record("Invalid interpreter must fail")
            } catch {}
        }
        #expect(openDescriptors() == before)
    }

    @Test("Codex checks stderr login status using the same bounded runner")
    func codexStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try "#!/bin/sh\nif [ \"$2\" = status ]; then printf 'Logged in using ChatGPT' >&2; fi\n".write(to: fixture.executable, atomically: true, encoding: .utf8)
        try await CodexAccountLoginService(executableURL: fixture.executable, loginTimeout: 3)
            .login(configurationDirectory: fixture.root)
    }

    @Test("Status capture is bounded and does not wait on a full pipe")
    func statusOutputLimit() async throws {
        let fixture = try Fixture(status: "/usr/bin/head -c 2097152 /dev/zero")
        defer { fixture.remove() }
        do {
            try await fixture.claude().login(configurationDirectory: fixture.root)
            Issue.record("Oversized status output must fail")
        } catch AccountLoginProcessRunner.Failure.outputLimitExceeded {}
    }

    private func expectTimeout(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Hanging login must time out")
        } catch AccountLoginProcessRunner.Failure.timedOut {
        } catch {
            Issue.record("Unexpected timeout error: \(error)")
        }
    }

    private func openDescriptors() -> Set<Int32> {
        Set((0..<1024).map(Int32.init).filter { fcntl($0, F_GETFD) != -1 })
    }

    private struct Fixture: Sendable {
        let root: URL
        let executable: URL
        var pidFile: URL { root.appending(path: "pid") }

        init(login: String = ":", status: String = "printf '{\"loggedIn\":true}'") throws {
            root = FileManager.default.temporaryDirectory.appending(path: "tokenremain-login-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            executable = root.appending(path: "fake-cli")
            let script = "#!/bin/sh\nif [ \"$2\" = login ]; then\n\(login)\nelse\n\(status)\nfi\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func claude(timeout: TimeInterval = 5, statusTimeout: TimeInterval = 1) -> ClaudeAccountLoginService {
            ClaudeAccountLoginService(executable: executable, loginTimeout: timeout, statusTimeout: statusTimeout)
        }

        func pid() throws -> Int32 {
            try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        func waitForPID() async throws {
            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: pidFile.path))
        }

        func expectChildStopped() throws {
            #expect(Darwin.kill(try pid(), 0) == -1)
            #expect(errno == ESRCH)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
