import Combine
import Foundation

/// One view-owned user action. Store methods bound reads and guard their commit
/// points; cancelling here propagates to them instead of only hiding a spinner.
@MainActor
final class AsyncViewAction: ObservableObject {
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?

    func start(_ operation: @escaping @MainActor () async -> Void) {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            defer {
                self?.isRunning = false
                self?.task = nil
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancel() { task?.cancel() }

    deinit { task?.cancel() }
}
