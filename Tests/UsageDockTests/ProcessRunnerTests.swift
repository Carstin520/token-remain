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
}
