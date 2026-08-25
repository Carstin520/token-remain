import Foundation

/// Keeps refresh work proportional to the chance that quota data changed.
/// Active local Codex/Claude sessions and visible UI retain minute-level
/// freshness. Once both are idle, expensive scans and account requests fall
/// back to at least five minutes; Apple devices still receive periodic Mac
/// snapshots without keeping an otherwise idle Mac on a one-minute work loop.
enum AdaptiveRefreshPolicy {
    static let activeInterval: TimeInterval = 60
    static let idleInterval: TimeInterval = 5 * 60
    static let maximumBackoff: TimeInterval = 5 * 60

    static func localAIQuotaInterval(
        preferred: TimeInterval?,
        lowLatencySyncEnabled: Bool,
        localSessionActive: Bool,
        primarySurfaceVisible: Bool
    ) -> TimeInterval? {
        if localSessionActive || primarySurfaceVisible {
            if let preferred {
                return min(preferred, activeInterval)
            }
            return lowLatencySyncEnabled ? activeInterval : nil
        }
        if let preferred {
            return max(preferred, idleInterval)
        }
        return lowLatencySyncEnabled ? idleInterval : nil
    }

    /// Providers unrelated to local Codex/Claude work keep the cadence the user
    /// selected. Apple-device sync uses a restrained five-minute fallback when
    /// the user selected manual-only refresh so it can still publish changes.
    static func auxiliaryQuotaInterval(
        preferred: TimeInterval?,
        lowLatencySyncEnabled: Bool
    ) -> TimeInterval? {
        preferred ?? (lowLatencySyncEnabled ? idleInterval : nil)
    }

    /// The inexpensive activity probe remains minute-level so a newly started
    /// session is noticed promptly. Full local-AI work runs only every five
    /// minutes when there is no visible surface or recent local session, while
    /// enabled auxiliary providers still retain the cadence selected by the
    /// user.
    static func schedulerInterval(
        localSessionActive: Bool,
        primarySurfaceVisible: Bool,
        auxiliaryQuotaInterval: TimeInterval?
    ) -> TimeInterval {
        let localAIInterval = (localSessionActive || primarySurfaceVisible)
            ? activeInterval
            : idleInterval
        guard let auxiliaryQuotaInterval else { return localAIInterval }
        return min(localAIInterval, auxiliaryQuotaInterval)
    }

    static func codexLocalSnapshotInterval(
        localSessionActive: Bool,
        primarySurfaceVisible: Bool
    ) -> TimeInterval {
        (localSessionActive || primarySurfaceVisible) ? activeInterval : idleInterval
    }

    static func retryDelay(after failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        let exponent = min(failureCount - 1, 8)
        return min(activeInterval * pow(2, Double(exponent)), maximumBackoff)
    }

    /// Claude 降级链的失败(尤其 PTY 探针超时)每次要付出最多 30 秒的
    /// 进程成本,持续性故障(登出、CLI 界面变化)下固定 5 分钟仍过于
    /// 频繁:以服务错误自带的首次延迟为底数按连续次数翻倍,上限半小时。
    static let escalatedMaximumBackoff: TimeInterval = 30 * 60

    static func escalatedRetryDelay(
        base: TimeInterval,
        consecutiveFailures: Int
    ) -> TimeInterval {
        guard consecutiveFailures > 1 else { return base }
        let exponent = min(consecutiveFailures - 1, 4)
        return min(base * pow(2, Double(exponent)), escalatedMaximumBackoff)
    }

    /// 本地 ccusage 扫描的节奏。它 spawn 一个 helper 进程重新解析近
    /// 30 天的会话日志,不能默默地每分钟跑:只有本地用量正被某个界面
    /// 展示、或 Apple 设备同步需要持续新鲜度时才值得分钟级;其余时间
    /// 跟随用户的普通刷新偏好,"仅手动"档完全不做后台扫描(打开界面
    /// 时的强制刷新不受影响)。
    static func localUsageInterval(
        preferred: TimeInterval?,
        lowLatencySyncEnabled: Bool,
        localUsageUIVisible: Bool,
        localSessionActive: Bool
    ) -> TimeInterval? {
        if localUsageUIVisible {
            return activeInterval
        }
        if localSessionActive {
            guard preferred != nil || lowLatencySyncEnabled else { return nil }
            return activeInterval
        }
        if let preferred {
            return max(preferred, idleInterval)
        }
        return lowLatencySyncEnabled ? idleInterval : nil
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
