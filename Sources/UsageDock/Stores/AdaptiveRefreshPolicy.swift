import Foundation

/// Keeps the companion freshness target independent from the user's ordinary
/// menu-bar refresh preference. Enabling Apple-device sync opts into a one-
/// minute capture loop; failures back off per provider so one rate-limited API
/// never slows local sources or unrelated providers.
enum AdaptiveRefreshPolicy {
    static let activeInterval: TimeInterval = 60
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

    /// 本地 ccusage 扫描的节奏。它 spawn 一个 helper 进程重新解析近
    /// 30 天的会话日志,不能默默地每分钟跑:只有本地用量正被某个界面
    /// 展示、或 Apple 设备同步需要持续新鲜度时才值得分钟级;其余时间
    /// 跟随用户的普通刷新偏好,"仅手动"档完全不做后台扫描(打开界面
    /// 时的强制刷新不受影响)。
    static func localUsageInterval(
        preferred: TimeInterval?,
        lowLatencySyncEnabled: Bool,
        localUsageUIVisible: Bool
    ) -> TimeInterval? {
        (lowLatencySyncEnabled || localUsageUIVisible) ? activeInterval : preferred
    }

    static func localUsageRefreshIsDue(
        interval: TimeInterval?,
        lastRefresh: Date?,
        now: Date,
        force: Bool
    ) -> Bool {
        if force { return true }
        guard let interval else { return false }
        return lastRefresh.map { now.timeIntervalSince($0) >= interval } != false
    }
}
