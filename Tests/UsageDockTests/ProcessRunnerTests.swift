import Foundation
import Testing
@testable import UsageDock

@Suite("Bounded local process runner")
struct ProcessRunnerTests {
    @Test("Successful probes return stdout")
    func returnsOutput() async throws {
        let output = try await ProcessRunner.run(
            "/bin/echo",
            arguments: ["automatic-sync"],
            timeout: 1
        )
        #expect(String(decoding: output, as: UTF8.self) == "automatic-sync\n")
    }

    @Test("Wedged probes are killed at the deadline")
    func timesOut() async {
        let startedAt = Date()
        do {
            _ = try await ProcessRunner.run(
                "/bin/sleep",
                arguments: ["5"],
                timeout: 0.05
            )
            Issue.record("sleep should not outlive the provider deadline")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("unexpected timeout error: \(error)")
        }
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test("A descendant holding stdout open cannot defeat the deadline")
    func inheritedPipeTimesOut() async {
        let startedAt = Date()
        do {
            _ = try await ProcessRunner.run(
                "/bin/sh",
                arguments: ["-c", "sleep 5 &"],
                timeout: 0.05
            )
            Issue.record("an inherited pipe must not hold the refresh open")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("unexpected timeout error: \(error)")
        }
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }
    @Test("Already cancelled callers never lose the completion callback")
    func alreadyCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run("/bin/sleep", arguments: ["5"], timeout: 0.05)
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Cancellation racing process setup always returns")
    func cancellationDuringSetup() async {
        for _ in 0..<30 {
            let task = Task { try await ProcessRunner.run("/bin/sleep", arguments: ["5"], timeout: 1) }
            await Task.yield()
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Expected cancellation")
            } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test("Cancelling an already running process terminates that process")
    func cancelsRunningProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "process-cancel-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await ProcessRunner.run("/bin/sh", arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 10", "probe", marker.path], timeout: 2)
        }
        let startDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pid = try #require(Int32(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        let stopDeadline = Date().addingTimeInterval(1)
        while kill(pid, 0) == 0, Date() < stopDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0)
    }

    @Test("Status commands preserve separate streams and nonzero exit status")
    func capturesNonzeroStatus() async throws {
        let output = try await ProcessRunner.capture(
            "/bin/sh", arguments: ["-c", "printf 'notice'; printf '{\"loggedIn\":false}' >&2; exit 1"], timeout: 1
        )
        #expect(output.status == 1)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "notice")
        #expect(ClaudeCLIAuthStatusParser.isExplicitlyLoggedOut(output.stderr))
    }

}
