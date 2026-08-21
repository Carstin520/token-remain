import Foundation

/// 什么时候该开口提醒用户重新登录。
///
/// 纯策略,和投递分开:SwiftPM 测试里没有 LaunchServices bundle,
/// `UNUserNotificationCenter` 根本用不了,而"要不要提醒"恰恰是唯一会出错的
/// 部分 —— 提醒不足,用户几天都不知道数据停了(实测一次 Claude 登出静静挂了
/// 44 小时,卡片始终显示着看上去很合理的旧额度);提醒过头,分钟级的刷新轮次
/// 会变成分钟级的横幅。
enum ProviderSessionAlerts {
    /// 沉默期。登出不会自己好,所以每天重提一次,而不是提醒一次就永远闭嘴。
    static let repeatInterval: TimeInterval = 24 * 3_600

    /// 只有"重新登录"才能解决的失败才值得打扰用户。
    ///
    /// 钥匙串未授权是另一回事(数据源页点一次授权就行),限流、超时和网络错误
    /// 会自己恢复 —— 把它们一起报成"请重新登录",用户照做也修不好,下次真的
    /// 登出时这条提醒就已经不值得信了。
    static func requiresSignIn(_ error: Error) -> Bool {
        if let claude = error as? ClaudeUsageService.ServiceError {
            switch claude {
            case .credentialsUnavailable, .sessionExpired, .invalidStoredCredentials:
                return true
            case .cliNotFound, .cliTimedOut, .credentialsAuthorizationRequired,
                 .cliLaunchFailed, .invalidUsageOutput, .rateLimited:
                return false
            }
        }
        if let codex = error as? CodexAPIUsageService.APIError {
            switch codex {
            case .notLoggedIn, .tokenExpired, .invalidStoredCredentials:
                return true
            case .credentialsAuthorizationRequired, .tokenRejected,
                 .requestFailed, .invalidResponse:
                return false
            }
        }
        return false
    }

    static func shouldAlert(lastAlertedAt: Date?, now: Date) -> Bool {
        guard let lastAlertedAt else { return true }
        // 未来的时间戳只可能来自改过的系统时钟。当作"该提醒"处理,免得一个坏
        // 时间戳把提醒永久压掉。
        let elapsed = now.timeIntervalSince(lastAlertedAt)
        return elapsed >= repeatInterval || elapsed < 0
    }

    static func defaultsKey(for provider: ProviderQuota.Provider) -> String {
        "tokenRemain.sessionAlert.\(provider.rawValue)"
    }
}

/// 把策略、沉默期存储和投递接起来。刷新链路上的调用点只需要陈述事实
/// (这轮成功了 / 这轮失败了),该不该出声由这里决定。
@MainActor
final class ProviderSessionAlertCenter {
    static let shared = ProviderSessionAlertCenter()

    private let defaults: UserDefaults
    private let notifications: UserNotificationService

    init(
        defaults: UserDefaults = .standard,
        notifications: UserNotificationService = .shared
    ) {
        self.defaults = defaults
        self.notifications = notifications
    }

    func report(error: Error, for provider: ProviderQuota.Provider, now: Date = .now) {
        guard ProviderSessionAlerts.requiresSignIn(error) else { return }
        let key = ProviderSessionAlerts.defaultsKey(for: provider)
        guard ProviderSessionAlerts.shouldAlert(
            lastAlertedAt: defaults.object(forKey: key) as? Date,
            now: now
        ) else {
            return
        }
        // 先记时间再投递:投递是异步的,失败了也不该让下一轮刷新(一分钟后)
        // 立刻再来一条。
        defaults.set(now, forKey: key)
        Task { await notifications.notifyProviderSignedOut(provider: provider) }
    }

    /// 恢复后清掉沉默期,这样下一次登出会立刻提醒,而不是被上一次那 24 小时
    /// 的窗口顺手吃掉。
    func reportHealthy(_ provider: ProviderQuota.Provider) {
        let key = ProviderSessionAlerts.defaultsKey(for: provider)
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        notifications.clearProviderSignedOut(provider: provider)
    }
}
