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
        timeout: TimeInterval = 30
    ) async throws -> Data {
        let execution = ProcessExecution(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await execution.run(timeout: max(timeout, 0.01))
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
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var output = Data()
    private var errorOutput = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var terminationStatus: Int32?
    private var finished = false

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func run(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

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
                finish(.failure(error))
                return
            }

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.timeOut()
            }
            lock.lock()
            if finished {
                lock.unlock()
                timeoutWorkItem.cancel()
            } else {
                self.timeoutWorkItem = timeoutWorkItem
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutWorkItem
                )
            }
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
        var result: Result<Data, Error>?
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
        var result: Result<Data, Error>?
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

    private func completionIfReadyLocked() -> Result<Data, Error>? {
        guard let terminationStatus, stdoutClosed, stderrClosed else { return nil }
        guard terminationStatus == 0 else {
            let detail = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(
                ProcessRunner.Failure(
                    message: detail?.isEmpty == false
                        ? detail!
                        : L10n.format("process.command_failed", terminationStatus)
                )
            )
        }
        return .success(output)
    }

    private func finish(_ result: Result<Data, Error>) {
        let continuation: CheckedContinuation<Data, Error>?
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
