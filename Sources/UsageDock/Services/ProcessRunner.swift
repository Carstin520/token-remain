import Darwin
import Foundation

enum ProcessRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A provider probe participates in a shared refresh round. A wedged or
    /// interactive CLI must not suspend automatic Mac-to-iPhone delivery.
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) async throws -> Data {
        let execution = ProcessExecution(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await execution.runToCompletion()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(timeout, 0.01)))
                    execution.stop()
                    throw URLError(.timedOut)
                }

                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw Failure(message: URLError(.unknown).localizedDescription)
                }
                return result
            }
        } onCancel: {
            execution.stop()
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func runToCompletion() async throws -> Data {
        try process.run()

        async let output = Task.detached(priority: .utility) { [stdout] in
            stdout.fileHandleForReading.readDataToEndOfFile()
        }.value
        async let errorOutput = Task.detached(priority: .utility) { [stderr] in
            stderr.fileHandleForReading.readDataToEndOfFile()
        }.value
        await Task.detached(priority: .utility) { [process] in
            process.waitUntilExit()
        }.value

        let (data, error) = await (output, errorOutput)
        guard process.terminationStatus == 0 else {
            let detail = String(data: error, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessRunner.Failure(
                message: detail?.isEmpty == false
                    ? detail!
                    : L10n.format("process.command_failed", process.terminationStatus)
            )
        }
        return data
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }

        process.terminate()
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
