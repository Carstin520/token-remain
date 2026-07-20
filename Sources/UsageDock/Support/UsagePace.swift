import Foundation

/// A current-window projection that compares actual consumption with the
/// straight-line budget available before the provider's real reset time.
///
/// This is intentionally a snapshot estimate, not a promise or fabricated
/// history. It becomes available only after at least 3% of the window elapsed,
/// which avoids noisy guidance immediately after a reset.
struct UsagePace: Sendable, Equatable {
    enum Status: Sendable {
        case onTrack
        case reserve
        case deficit
    }

    let status: Status
    let expectedUsedPercent: Double
    let actualUsedPercent: Double
    let deltaPercent: Double
    let estimatedRunOutAt: Date?
    let willLastUntilReset: Bool

    /// The compact remaining label stays quiet for healthy or reserve pacing.
    /// Only above-budget consumption needs an attention icon.
    var showsRemainingWarning: Bool {
        if case .deficit = status {
            return true
        }
        return false
    }

    init?(window: QuotaWindow, now: Date = .now) {
        guard let resetsAt = window.resetsAt, window.windowMinutes > 0 else { return nil }

        let duration = TimeInterval(window.windowMinutes * 60)
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }

        let elapsed = duration - timeUntilReset
        let expected = min(100, max(0, elapsed / duration * 100))
        guard expected >= 3 else { return nil }

        let actual = min(100, max(0, window.usedPercent))
        let delta = actual - expected

        if abs(delta) <= 2 {
            status = .onTrack
        } else {
            status = delta > 0 ? .deficit : .reserve
        }

        expectedUsedPercent = expected
        actualUsedPercent = actual
        deltaPercent = delta

        guard actual > 0, elapsed > 0, actual < 100 else {
            estimatedRunOutAt = actual >= 100 ? now : nil
            willLastUntilReset = actual < 100
            return
        }

        let usedPercentPerSecond = actual / elapsed
        let secondsUntilEmpty = (100 - actual) / usedPercentPerSecond
        if secondsUntilEmpty >= timeUntilReset {
            estimatedRunOutAt = nil
            willLastUntilReset = true
        } else {
            estimatedRunOutAt = now.addingTimeInterval(secondsUntilEmpty)
            willLastUntilReset = false
        }
    }
}
