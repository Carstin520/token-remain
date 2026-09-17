import Darwin
import Foundation

enum ProcessRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A provider probe participates in a shared refresh round. A wedged or
    /// interactive CLI must not suspend automatic desktop snapshot delivery.
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        let output = try await capture(
            executable, arguments: arguments, environment: environment, timeout: timeout
        )
        guard output.status == 0 else {
            let detail = String(data: output.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail?.isEmpty == false
                ? detail! : L10n.format("process.command_failed", output.status))
        }
        return output.stdout
    }

    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    /// Some status commands report valid JSON on stderr or use a nonzero exit
    /// for signed-out state. Drain both streams with the same deadline.
    static func capture(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Output {
        try Task.checkCancellation()
        let execution = ProcessExecution(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        return try await withTaskCancellationHandler {
            let output = try await execution.run(timeout: max(timeout, 0.01))
            try Task.checkCancellation()
            return output
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessRunner.Output, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var output = Data()
    private var errorOutput = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var terminationStatus: Int32?
    private var finished = false

    init(executable: String, arguments: [String], environment: [String: String]?) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func run(timeout: TimeInterval) async throws -> ProcessRunner.Output {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            // Keep setup/start under the same lock as cancellation. Otherwise
            // cancel can finish before the continuation exists, or stop a
            // not-yet-started process which is then launched without a timer.
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.consume(handle.availableData, fromStandardError: false)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.consume(handle.availableData, fromStandardError: true)
            }
            process.terminationHandler = { [weak self] process in
                self?.didTerminate(status: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                lock.unlock()
                finish(.failure(error))
                return
            }

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.timeOut()
            }
            self.timeoutWorkItem = timeoutWorkItem
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
        stopProcess()
    }

    private func timeOut() {
        finish(.failure(URLError(.timedOut)))
        stopProcess()
    }

    private func consume(_ data: Data, fromStandardError: Bool) {
        var result: Result<ProcessRunner.Output, Error>?
        lock.lock()
        if !finished {
            if data.isEmpty {
                if fromStandardError {
                    stderrClosed = true
                } else {
                    stdoutClosed = true
                }
            } else if fromStandardError {
                errorOutput.append(data)
            } else {
                output.append(data)
            }
            result = completionIfReadyLocked()
        }
        lock.unlock()
        if let result {
            finish(result)
        }
    }

    private func didTerminate(status: Int32) {
        var result: Result<ProcessRunner.Output, Error>?
        lock.lock()
        if !finished {
            terminationStatus = status
            result = completionIfReadyLocked()
        }
        lock.unlock()
        if let result {
            finish(result)
        }
    }

    private func completionIfReadyLocked() -> Result<ProcessRunner.Output, Error>? {
        guard let terminationStatus, stdoutClosed, stderrClosed else { return nil }
        return .success(ProcessRunner.Output(stdout: output, stderr: errorOutput, status: terminationStatus))
    }

    private func finish(_ result: Result<ProcessRunner.Output, Error>) {
        let continuation: CheckedContinuation<ProcessRunner.Output, Error>?
        let timeoutWorkItem: DispatchWorkItem?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation = self.continuation
        self.continuation = nil
        timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        continuation?.resume(with: result)
    }

    private func stopProcess() {
        guard process.isRunning else { return }
        let process = self.process
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }
}
