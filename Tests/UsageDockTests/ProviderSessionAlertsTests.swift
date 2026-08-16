import Foundation
import Testing
@testable import UsageDock

/// 提醒策略。这里判错的代价是不对称的:漏提醒,用户几天都不知道数据停了
/// (实测一次 Claude 登出静静挂了 44 小时);滥提醒,分钟级的刷新轮次会变成
/// 分钟级的横幅,几天后这条提醒就再也没人看了。
@Suite("Provider session alerts")
struct ProviderSessionAlertsTests {
    @Test("Only failures that sign-in can fix are worth interrupting for")
    func onlySignInFailuresAlert() {
        #expect(ProviderSessionAlerts.requiresSignIn(ClaudeUsageService.ServiceError.credentialsUnavailable))
        #expect(ProviderSessionAlerts.requiresSignIn(ClaudeUsageService.ServiceError.sessionExpired))
        #expect(ProviderSessionAlerts.requiresSignIn(ClaudeUsageService.ServiceError.invalidStoredCredentials))
        #expect(ProviderSessionAlerts.requiresSignIn(CodexAPIUsageService.APIError.notLoggedIn))
        #expect(ProviderSessionAlerts.requiresSignIn(CodexAPIUsageService.APIError.tokenExpired))
    }

    @Test("Failures with a different remedy stay quiet")
    func otherFailuresStayQuiet() {
        // 授权问题的解法是数据源页点一次授权,不是重新登录。
        #expect(!ProviderSessionAlerts.requiresSignIn(ClaudeUsageService.ServiceError.credentialsAuthorizationRequired))
        // 超时曾经是登出的伪装 —— 现在登出会被识别成登出,超时就该老实当超时,
        // 它会自己恢复,不值得推一条"请重新登录"。
        #expect(!ProviderSessionAlerts.requiresSignIn(ClaudeUsageService.ServiceError.cliTimedOut))
        #expect(!ProviderSessionAlerts.requiresSignIn(ClaudeUsageService.ServiceError.rateLimited(retryAfterSeconds: 60)))
        #expect(!ProviderSessionAlerts.requiresSignIn(ClaudeUsageService.ServiceError.cliNotFound))
        #expect(!ProviderSessionAlerts.requiresSignIn(CodexAPIUsageService.APIError.requestFailed(500)))
        #expect(!ProviderSessionAlerts.requiresSignIn(URLError(.notConnectedToInternet)))
    }

    @Test("A signed-out account is reminded about daily, not every refresh round")
    func remindsDailyRatherThanEveryRound() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ProviderSessionAlerts.shouldAlert(lastAlertedAt: nil, now: now))
        #expect(!ProviderSessionAlerts.shouldAlert(lastAlertedAt: now.addingTimeInterval(-60), now: now))
        #expect(!ProviderSessionAlerts.shouldAlert(lastAlertedAt: now.addingTimeInterval(-23 * 3_600), now: now))
        #expect(ProviderSessionAlerts.shouldAlert(lastAlertedAt: now.addingTimeInterval(-25 * 3_600), now: now))
        // 时钟被改到过去会留下一个未来的时间戳。宁可多提醒一次,也不要让它把
        // 提醒永久压死。
        #expect(ProviderSessionAlerts.shouldAlert(lastAlertedAt: now.addingTimeInterval(3_600), now: now))
    }
}

@Suite("Provider session alert center")
@MainActor
struct ProviderSessionAlertCenterTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "tokenremain-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func key(_ provider: ProviderQuota.Provider) -> String {
        ProviderSessionAlerts.defaultsKey(for: provider)
    }

    @Test("The first sign-out is announced and the next refresh round is not")
    func announcesOnceThenHoldsQuiet() {
        let defaults = makeDefaults()
        let center = ProviderSessionAlertCenter(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        center.report(error: ClaudeUsageService.ServiceError.credentialsUnavailable, for: .claude, now: now)
        let stamped = defaults.object(forKey: key(.claude)) as? Date
        #expect(stamped == now)

        // 一分钟后的下一轮刷新看到同一个错误,不该再推一条。
        center.report(
            error: ClaudeUsageService.ServiceError.credentialsUnavailable,
            for: .claude,
            now: now.addingTimeInterval(60)
        )
        #expect(defaults.object(forKey: key(.claude)) as? Date == stamped)
    }

    @Test("A failure with another remedy never stamps the silence window")
    func unrelatedFailureLeavesNoTrace() {
        let defaults = makeDefaults()
        let center = ProviderSessionAlertCenter(defaults: defaults)

        center.report(error: ClaudeUsageService.ServiceError.cliTimedOut, for: .claude)

        #expect(defaults.object(forKey: key(.claude)) == nil)
    }

    /// 恢复必须清掉沉默期。否则用户今天重新登录、明天又被登出,那次登出会被
    /// 上一次留下的 24 小时窗口悄悄吃掉 —— 而这正是这个功能要防的场景。
    @Test("Recovery re-arms the reminder for the next sign-out")
    func recoveryReArmsTheReminder() {
        let defaults = makeDefaults()
        let center = ProviderSessionAlertCenter(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        center.report(error: ClaudeUsageService.ServiceError.credentialsUnavailable, for: .claude, now: now)
        #expect(defaults.object(forKey: key(.claude)) != nil)

        center.reportHealthy(.claude)
        #expect(defaults.object(forKey: key(.claude)) == nil)

        let later = now.addingTimeInterval(600)
        center.report(error: ClaudeUsageService.ServiceError.credentialsUnavailable, for: .claude, now: later)
        #expect(defaults.object(forKey: key(.claude)) as? Date == later)
    }

    @Test("Providers hold separate silence windows")
    func providersAreIndependent() {
        let defaults = makeDefaults()
        let center = ProviderSessionAlertCenter(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        center.report(error: ClaudeUsageService.ServiceError.credentialsUnavailable, for: .claude, now: now)
        #expect(defaults.object(forKey: key(.codex)) == nil)

        center.report(error: CodexAPIUsageService.APIError.notLoggedIn, for: .codex, now: now)
        #expect(defaults.object(forKey: key(.codex)) as? Date == now)
    }
}
