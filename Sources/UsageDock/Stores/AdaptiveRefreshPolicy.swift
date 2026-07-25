import Foundation

/// Keeps the companion freshness target independent from the user's ordinary
/// menu-bar refresh preference. Enabling Apple-device sync opts into a one-
/// minute capture loop; failures back off per provider so one rate-limited API
/// never slows local sources or unrelated providers.
enum AdaptiveRefreshPolicy {
    static let activeInterval: TimeInterval = 60
    /// Local ccusage data changes whenever an agent writes a new session event.
    /// Keep it on the same minute cadence as the running app so an open
    /// dashboard cannot remain stale until the next five-minute provider poll.
    static let localUsageInterval: TimeInterval = activeInterval
    static let maximumBackoff: TimeInterval = 5 * 60

    static func interval(
        preferred: TimeInterval?,
        lowLatencySyncEnabled: Bool
    ) -> TimeInterval? {
        lowLatencySyncEnabled ? activeInterval : preferred
    }

    static func retryDelay(after failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        let exponent = min(failureCount - 1, 8)
        return min(activeInterval * pow(2, Double(exponent)), maximumBackoff)
    }

    static func localUsageRefreshIsDue(
        lastRefresh: Date?,
        now: Date,
        force: Bool
    ) -> Bool {
        force
            || lastRefresh.map {
                now.timeIntervalSince($0) >= localUsageInterval
            } != false
    }
}
