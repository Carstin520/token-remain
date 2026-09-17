import Foundation

/// Bounds read/validation work even when an underlying callback ignores Swift
/// cancellation. Only return values cross this boundary; callers must commit
/// credentials or UI state afterwards, after checking cancellation again.
enum AsyncDeadline {
    static let providerTimeout: TimeInterval = 90

    enum Failure: LocalizedError {
        case timedOut
        var errorDescription: String? { L10n.text("operation.timed_out") }
    }

    static func message(for error: Error) -> String {
        error is CancellationError ? L10n.text("operation.cancelled") : error.localizedDescription
    }

    static func run<Value: Sendable>(
        timeout: TimeInterval = providerTimeout,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let race = DeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            let value = try await withCheckedThrowingContinuation { continuation in
                guard race.install(continuation) else { return }
                let worker = Task.detached(priority: Task.currentPriority) {
                    do {
                        try Task.checkCancellation()
                        let value = try await operation()
                        try Task.checkCancellation()
                        race.finish(.success(value))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                let timer = Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(max(0.001, timeout)))
                        race.finish(.failure(Failure.timedOut))
                    } catch {}
                }
                race.attach(worker: worker, timer: timer)
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// The lock serializes completion, including cancellation before installation.
/// A task group is unsuitable here: it waits for an uncooperative child to end.
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func attach(worker: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            worker.cancel()
            timer.cancel()
        } else {
            self.worker = worker
            self.timer = timer
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let worker = self.worker
        let timer = self.timer
        self.continuation = nil
        self.worker = nil
        self.timer = nil
        lock.unlock()
        worker?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
