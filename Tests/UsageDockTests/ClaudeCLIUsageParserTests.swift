import Foundation
import Testing
@testable import UsageDock

@Suite("Claude CLI auth status parser")
struct ClaudeCLIAuthStatusParserTests {
    @Test("Recognizes an explicit logged-out status")
    func recognizesLoggedOutStatus() {
        let output = #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#
        #expect(ClaudeCLIAuthStatusParser.isExplicitlyLoggedOut(Data(output.utf8)))
    }

    @Test("Does not treat logged-in or malformed output as logged out")
    func ignoresOtherOutput() {
        #expect(!ClaudeCLIAuthStatusParser.isExplicitlyLoggedOut(Data(#"{"loggedIn":true}"#.utf8)))
        #expect(!ClaudeCLIAuthStatusParser.isExplicitlyLoggedOut(Data("not json".utf8)))
    }
}

/// 决定"要不要先问一句 Claude Code 是否已登出"的判据。判错的代价不对称:
/// 漏判会让探针在登录界面上空转满 45 秒,然后把"账号登出了"报成"读取超时",
/// 用户照着错误提示怎么修都修不好。
@Suite("Claude signed-out detection")
struct ClaudeSignedOutDetectionTests {
    @Test("Every credential failure is checked against the CLI session")
    func credentialFailuresAskTheCLI() {
        // 钥匙串条目被重写后返回 errSecAuthFailed —— 这条路径和"找不到凭证"
        // 长得完全不一样,却同样意味着 Claude Code 没有会话可用。
        #expect(ClaudeUsageService.mayReflectSignedOutClaude(.credentialsAuthorizationRequired))
        #expect(ClaudeUsageService.mayReflectSignedOutClaude(.credentialsUnavailable))
        #expect(ClaudeUsageService.mayReflectSignedOutClaude(.credentialsExpired))
        #expect(ClaudeUsageService.mayReflectSignedOutClaude(.invalidStoredCredentials))
        #expect(ClaudeUsageService.mayReflectSignedOutClaude(.tokenRejected(401)))
    }

    @Test("Transport and protocol failures do not imply a signed-out session")
    func transportFailuresSkipTheAuthCheck() {
        // 这些和会话状态无关,不值得为它们先花一次 `auth status` 询问。
        #expect(!ClaudeUsageService.mayReflectSignedOutClaude(.requestFailed(500)))
        #expect(!ClaudeUsageService.mayReflectSignedOutClaude(.invalidResponse))
        #expect(!ClaudeUsageService.mayReflectSignedOutClaude(.rateLimited(retryAfterSeconds: 60)))
    }
}

/// PTY 降级一次要付出最多 45 秒的进程成本,只有探针可能修复的失败才值得:
/// 凭证类失败靠探针里的 Claude Code 自行续期,`invalidResponse` 靠 /usage
/// 画面兜底。网络或服务端故障时探针读的是同一个接口,降级只会把一个普通
/// 故障拖成一条误导性的"读取超时"。
@Suite("Claude PTY fallback gating")
struct ClaudePTYFallbackGatingTests {
    @Test("Credential-shaped failures are worth a probe")
    func credentialFailuresProbe() {
        #expect(ClaudeUsageService.probeCanRecover(from: .credentialsUnavailable))
        #expect(ClaudeUsageService.probeCanRecover(from: .credentialsAuthorizationRequired))
        #expect(ClaudeUsageService.probeCanRecover(from: .credentialsExpired))
        #expect(ClaudeUsageService.probeCanRecover(from: .invalidStoredCredentials))
        #expect(ClaudeUsageService.probeCanRecover(from: .tokenRejected(401)))
    }

    @Test("An API response without a subscription session row still probes")
    func inferenceOnlyAccountsProbe() {
        // 部分账户的 oauth/usage 不含订阅会话行,/usage 画面是唯一数据源。
        #expect(ClaudeUsageService.probeCanRecover(from: .invalidResponse))
    }

    @Test("Server-side failures never probe")
    func serverFailuresDoNotProbe() {
        #expect(!ClaudeUsageService.probeCanRecover(from: .requestFailed(500)))
        #expect(!ClaudeUsageService.probeCanRecover(from: .rateLimited(retryAfterSeconds: 60)))
        #expect(!ClaudeUsageService.probeCanRecover(from: .rateLimited(retryAfterSeconds: nil)))
    }
}

/// PTY 可能在 Claude Code 已经续期后才因终端输出不完整而失败。恢复路径
/// 只能依据只读重读得到的新 token，不能自己续期，也不能拿旧 token 重打 API。
@Suite("Claude PTY credential recovery")
struct ClaudePTYCredentialRecoveryTests {
    @Test("A newly usable token retries the API once and returns its quota")
    func retriesAfterTokenRefresh() async throws {
        let expected = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: "Max",
            capturedAt: .now
        )

        let recovered = try await ClaudeUsageService.retryOAuthAfterCredentialRefresh(
            previousAccessToken: "expired-token",
            readCurrentAccessToken: { "renewed-token" },
            fetchOAuthUsage: { expected }
        )

        #expect(recovered?.primary.usedPercent == 12)
        #expect(recovered?.planName == "Max")
    }

    @Test("The same token never causes a second API request")
    func skipsRetryForUnchangedToken() async throws {
        let recovered = try await ClaudeUsageService.retryOAuthAfterCredentialRefresh(
            previousAccessToken: "same-token",
            readCurrentAccessToken: { "same-token" },
            fetchOAuthUsage: {
                Issue.record("an unchanged token must not retry oauth/usage")
                return ProviderQuota(
                    provider: .claude,
                    primary: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil),
                    secondary: nil,
                    planName: nil,
                    capturedAt: .now
                )
            }
        )

        #expect(recovered == nil)
    }

    @Test("A previously unavailable credential may recover to a usable token")
    func retriesWhenMissingCredentialBecomesUsable() async throws {
        let recovered = try await ClaudeUsageService.retryOAuthAfterCredentialRefresh(
            previousAccessToken: nil,
            readCurrentAccessToken: { "renewed-token" },
            fetchOAuthUsage: {
                ProviderQuota(
                    provider: .claude,
                    primary: QuotaWindow(usedPercent: 34, windowMinutes: 300, resetsAt: nil),
                    secondary: nil,
                    planName: nil,
                    capturedAt: .now
                )
            }
        )

        #expect(recovered?.primary.usedPercent == 34)
    }
}

@Suite("Claude recovery without the CLI")
struct ClaudeNoCLIFallbackTests {
    @Test("Preserves actionable credential states")
    func mapsCredentialFailures() throws {
        let authorization = try #require(
            ClaudeUsageService.noCLIFallbackError(
                for: .credentialsAuthorizationRequired
            ) as? ClaudeUsageService.ServiceError
        )
        let rejected = try #require(
            ClaudeUsageService.noCLIFallbackError(
                for: .credentialsExpired
            ) as? ClaudeUsageService.ServiceError
        )
        let invalid = try #require(
            ClaudeUsageService.noCLIFallbackError(
                for: .invalidResponse
            ) as? ClaudeUsageService.ServiceError
        )

        guard case .credentialsAuthorizationRequired = authorization else {
            Issue.record("blocked Keychain access must request explicit authorization")
            return
        }
        guard case .sessionExpired = rejected else {
            Issue.record("a rejected token must direct the user to renew the desktop session")
            return
        }
        guard case .invalidUsageOutput = invalid else {
            Issue.record("an invalid API response must retain its diagnostic meaning")
            return
        }
    }
}

@Suite("Claude CLI usage parser")
struct ClaudeCLIUsageParserTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "pty", subdirectory: "Fixtures")
        )
        let escaped = try String(contentsOf: url, encoding: .utf8)
        let raw = escaped
            .replacingOccurrences(of: "<ESC>", with: "\u{001B}")
            .replacingOccurrences(of: "<CR>", with: "\r")
        return Data(raw.utf8)
    }

    @Test("Parses the sanitized live PTY capture without inventing Fable")
    func parsesSanitizedLiveCapture() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-13T08:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let quota = try ClaudeCLIUsageParser.parse(
            fixture("claude-usage-2.1.220-live-old-layout"),
            now: now,
            calendar: calendar
        )

        #expect(quota.primary.usedPercent == 8)
        #expect(quota.secondary?.usedPercent == 56)
        #expect(quota.primary.resetsAt == ISO8601DateFormatter().date(from: "2026-08-13T11:30:00Z"))
        #expect(quota.secondary?.resetsAt == ISO8601DateFormatter().date(from: "2026-08-14T05:00:00Z"))
        #expect(quota.fableWindow == nil)
    }

    @Test("Parses Weekly limits rows and ignores banner and help copy")
    func parsesNewWeeklyLimitsLayout() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-13T00:00:00Z"))
        let data = try fixture("claude-usage-new-weekly-limits")

        let quota = try ClaudeCLIUsageParser.parse(data, now: now)

        #expect(ClaudeCLIUsageParser.hasCompleteUsage(in: data))
        #expect(quota.primary.usedPercent == 7)
        #expect(quota.secondary?.usedPercent == 57)
        #expect(quota.primary.resetsAt == now.addingTimeInterval(3 * 3_600 + 56 * 60))
        #expect(quota.secondary?.resetsAt == now.addingTimeInterval(21 * 3_600 + 26 * 60))
        let fable = try #require(quota.fableWindow)
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
        #expect(fable.window.usedPercent == 98)
        #expect(fable.window.resetsAt == quota.secondary?.resetsAt)
    }

    @Test("Parses the current Claude usage screen in reading order")
    func parsesCurrentClaudeUsageScreenByReadingOrder() throws {
        let output = """
        Claude Code v2.1.201
        Total cost: $0.0000
        Current session
        4% used
        Resets 11:50pm (Asia/Shanghai) │
        Current week (all models)
        0%used
        Resets Jul 24 at 1pm (Asia/Shanghai)
        Current week (Fable)
        0% used
        """
        // 23:50 local has to stay inside the five-hour window it belongs to;
        // a session reset further out than that is now rejected as damage.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-17T15:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8), now: now, calendar: calendar)

        #expect(quota.primary.usedPercent == 4)
        #expect(quota.secondary?.usedPercent == 0)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.windowMinutes == 10_080)
        let fable = try #require(quota.scopedWindows?.first)
        #expect(fable.scopeID == "fable")
        #expect(fable.displayName == "Fable")
        #expect(fable.window.usedPercent == 0)
        #expect(fable.window.windowMinutes == 10_080)
        #expect(quota.primary.resetsAt != nil)
        #expect(
            quota.secondary?.resetsAt
                == ISO8601DateFormatter().date(from: "2026-07-24T05:00:00Z")
        )
    }

    @Test("Converts remaining percentages to used percentages")
    func convertsRemainingPercentToUsedPercent() throws {
        let output = """
        Current session
        95% left
        Resets 6pm
        Current week
        80% remaining
        Resets Jul 24
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

        #expect(quota.primary.usedPercent == 5)
        #expect(quota.secondary?.usedPercent == 20)
    }

    @Test("Ignores promotional percentages without a usage direction")
    func ignoresPromotionalPercentWithoutUsageDirection() throws {
        let output = """
        Weekly rate limits are 50% higher through July 19.
        Current session
        12% used
        Resets 9pm
        Current week
        34% used
        Resets Jul 24 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

        #expect(quota.primary.usedPercent == 12)
        #expect(quota.secondary?.usedPercent == 34)
    }

    @Test("Matches reset times by window shape when terminal rows are reordered")
    func matchesResetTimesByWindowShape() throws {
        let output = """
        Current session
        8% used
        Current week
        1% used
        Resets Jul 24 at 1pm
        Current week (Fable)
        Resets Jul 24 at 1pm
        """
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-20T00:00:00Z"))

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8), now: now)

        #expect(quota.primary.resetsAt == nil)
        #expect(quota.secondary?.resetsAt != nil)
    }

    @Test("Keeps only the latest model window when the terminal repaints Fable")
    func deduplicatesRepaintedFableWindow() throws {
        let output = """
        Current session
        8% used
        Current week (all models)
        7% used
        Resets Jul 31 at 1pm
        Current week (Fable)
        12% used
        Resets Jul 31 at 1pm
        Current week (Fable)
        14% used
        Resets Aug 1 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))
        let scoped = try #require(quota.scopedWindows)

        #expect(scoped.count == 1)
        #expect(scoped[0].scopeID == "fable")
        #expect(scoped[0].window.usedPercent == 14)
    }

    @Test(
        "A repainted all-models label is not treated as a model quota",
        arguments: ["all odels", "ll models", "ll model", "all model", "all  models"]
    )
    func ignoresDamagedAllModelsLabel(damagedLabel: String) throws {
        let output = """
        Current session
        8% used
        Current week (\(damagedLabel))
        7% used
        Resets Jul 31 at 1pm
        Current week (Fable)
        14% used
        Resets Aug 1 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
    }

    @Test("Real model labels survive the all-models filter")
    func keepsRealModelLabels() throws {
        let output = """
        Current session
        8% used
        Current week (all models)
        7% used
        Resets Jul 31 at 1pm
        Current week (Opus)
        20% used
        Resets Aug 1 at 1pm
        Current week (Fable)
        14% used
        Resets Aug 1 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["opus", "fable"])
    }
}

@Suite("Claude CLI usage probe decisions")
struct ClaudeCLIUsageProbeDecisionTests {
    private let startedAt = Date(timeIntervalSince1970: 1_000)

    @Test("Detects the ANSI-painted folder trust prompt without spaces")
    func detectsTrustPrompt() {
        let output = """
        \u{001B}[1mQuicksafetycheck:\u{001B}[0mIsthisaprojectyoucreatedoroneyoutrust
        \u{001B}[36m1.Yes,Itrustthisfolder\u{001B}[0m
        """

        #expect(ClaudeCLIUsageParser.containsTrustPrompt(in: Data(output.utf8)))
    }

    @Test("Does not mistake a normal usage screen for the trust prompt")
    func ignoresUsageScreenForTrustPrompt() {
        let output = """
        Current session
        8% used
        Resets 11:40am
        Current week (all models)
        60% used
        """

        #expect(!ClaudeCLIUsageParser.containsTrustPrompt(in: Data(output.utf8)))
    }

    @Test("Sends the initial usage command after the startup interval")
    func sendsInitialUsageCommand() {
        #expect(
            ClaudeCLIUsageParser.shouldSendUsageCommand(
                in: Data(),
                startedAt: startedAt,
                lastSentAt: nil,
                now: startedAt.addingTimeInterval(5)
            )
        )
    }

    @Test("Re-sends the usage command after five seconds without a session section")
    func resendsUsageCommand() {
        let lastSentAt = startedAt.addingTimeInterval(5)

        #expect(
            ClaudeCLIUsageParser.shouldSendUsageCommand(
                in: Data("Claude Code is starting".utf8),
                startedAt: startedAt,
                lastSentAt: lastSentAt,
                now: lastSentAt.addingTimeInterval(5)
            )
        )
    }

    @Test("Stops sending once the current session section appears")
    func stopsSendingUsageCommand() {
        let lastSentAt = startedAt.addingTimeInterval(5)
        let output = Data("\u{001B}[1mCurrent session\u{001B}[0m\n8% used".utf8)

        #expect(
            !ClaudeCLIUsageParser.shouldSendUsageCommand(
                in: output,
                startedAt: startedAt,
                lastSentAt: lastSentAt,
                now: lastSentAt.addingTimeInterval(5)
            )
        )
    }
}

@Suite("Scoped quota window sanitation")
struct ScopedQuotaWindowSanitationTests {
    private func scoped(_ scopeID: String, _ displayName: String) -> ScopedQuotaWindow {
        ScopedQuotaWindow(
            scopeID: scopeID,
            displayName: displayName,
            window: QuotaWindow(usedPercent: 5, windowMinutes: 10_080, resetsAt: nil)
        )
    }

    @Test("Drops all-models rows cached by an earlier build")
    func purgesCachedGeneralWeeklyRows() {
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 47, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 5, windowMinutes: 10_080, resetsAt: nil),
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                scoped("ll_model", "ll model"),
                scoped("ll_models", "ll models"),
                scoped("fable", "Fable")
            ]
        )

        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
    }

    @Test("Keeps scopes that merely share letters with the label")
    func keepsUnrelatedScopes() {
        #expect(!ScopedQuotaWindow.isGeneralWeeklyLabel("Fable"))
        #expect(!ScopedQuotaWindow.isGeneralWeeklyLabel("Opus"))
        #expect(!ScopedQuotaWindow.isGeneralWeeklyLabel("Monthly"))
        #expect(!ScopedQuotaWindow.isGeneralWeeklyLabel("MCP"))
        #expect(!ScopedQuotaWindow.isGeneralWeeklyLabel("Claude / Third-party"))
        #expect(!ScopedQuotaWindow.isGeneralWeeklyLabel("modes"))
        #expect(ScopedQuotaWindow.isGeneralWeeklyLabel("all models"))
        #expect(ScopedQuotaWindow.isGeneralWeeklyLabel("ll models"))
    }
}

/// `Current session (X)` 是模型级会话额度,不是账户 5 小时窗。旧解析器
/// 不看括号、last-wins,一条模型级会话行就能顶掉账户读数(审计 🟠 项)。
@Suite("Claude PTY scoped session rows")
struct ClaudePTYScopedSessionRowTests {
    private func shanghai() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        return calendar
    }

    /// 09:39 Asia/Shanghai,和 repaint recovery 套件同一观测时刻。
    private func morning() throws -> Date {
        try #require(ISO8601DateFormatter().date(from: "2026-08-14T01:39:00Z"))
    }

    @Test("A scoped session row becomes a scoped window instead of the account 5h")
    func scopedSessionRowDoesNotReplaceAccountSession() throws {
        // scoped 行画在账户行之后:旧的 last-wins 会把账户 5h 显示成 88%。
        // 同屏还有一份重绘的旧拷贝(80%),必须按最后一份完整读数去重。
        let output = """
        Current session
        12% used
        Resets 11:40am
        Current session (Fable)
        80% used
        Resets 11:40am
        Current session (Fable)
        88% used
        Resets 11:40am
        Current week (all models)
        60% used
        Resets Aug 14 at 1pm
        Current week (Fable)
        98% used
        Resets Aug 14 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(
            Data(output.utf8),
            now: try morning(),
            calendar: try shanghai()
        )

        #expect(quota.primary.usedPercent == 12)
        #expect(quota.secondary?.usedPercent == 60)
        // 会话窗在前、周窗在后,呼应主卡 5h+7d 的堆叠顺序。
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable_session", "fable"])
        let fableSession = try #require(quota.uniqueScopedWindows.first)
        #expect(fableSession.displayName == "Fable")
        #expect(fableSession.window.usedPercent == 88)
        #expect(fableSession.window.windowMinutes == 300)
        #expect(fableSession.window.resetsAt == quota.primary.resetsAt)
        #expect(fableSession.isFable)
    }

    @Test("A scoped session row without its own reset borrows the account session reset")
    func scopedSessionFallsBackToAccountReset() throws {
        let output = """
        Current session
        12% used
        Resets 11:40am
        Current session (Fable)
        88% used
        Current week (all models)
        60% used
        Resets Aug 14 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(
            Data(output.utf8),
            now: try morning(),
            calendar: try shanghai()
        )
        let fableSession = try #require(
            quota.uniqueScopedWindows.first { $0.scopeID == "fable_session" }
        )

        #expect(quota.primary.resetsAt != nil)
        #expect(fableSession.window.resetsAt == quota.primary.resetsAt)
    }

    @Test("A screen with only scoped session rows is not a complete account reading")
    func scopedSessionAloneDoesNotSatisfyTheParser() throws {
        let output = """
        Current session (Fable)
        88% used
        Resets 11:40am
        Current week (all models)
        60% used
        Resets Aug 14 at 1pm
        """

        // 账户级 5 小时读数缺席时宁可整体判为未画全,也不能把模型级
        // 会话额度冒充成账户窗口。
        #expect(!ClaudeCLIUsageParser.hasCompleteUsage(in: Data(output.utf8)))
        #expect(throws: (any Error).self) {
            try ClaudeCLIUsageParser.parse(
                Data(output.utf8),
                now: try morning(),
                calendar: try shanghai()
            )
        }
    }

    @Test("An unterminated scoped session header is dropped entirely")
    func dropsUnterminatedScopedSessionHeader() throws {
        // 重绘丢掉了闭括号:该拷贝属于哪个 scope 已不可判,既不能当
        // 账户读数,也不能当 scoped 读数——与 weekly 侧的处理一致。
        let output = """
        Current session (Fable
        88% used
        Resets 11:40am
        Current session
        12% used
        Resets 11:40am
        Current week (all models)
        60% used
        Resets Aug 14 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(
            Data(output.utf8),
            now: try morning(),
            calendar: try shanghai()
        )

        #expect(quota.primary.usedPercent == 12)
        #expect(quota.uniqueScopedWindows.isEmpty)
    }
}

@Suite("Claude PTY repaint recovery")
struct ClaudePTYRepaintRecoveryTests {
    @Test("An unterminated scoped label cannot absorb progress and reset lines")
    func dropsUnterminatedScopedLabel() throws {
        let output = """
        Current session
        12% used
        Resets 9am
        Current week (all models)
        22% used
        Resets Aug 14 at 1pm
        Current week (Fable)
        40% used
        Resets Aug 14 at 1pm
        Current week (Fable
        ████████████████████    40%used
        Resets Aug14 at 12:59pm(Asia/Shanghai)
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
        #expect(quota.uniqueScopedWindows.first?.displayName == "Fable")
    }

    private func shanghai() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        return calendar
    }

    /// 09:39 Asia/Shanghai on the morning the corrupt readings were observed.
    private func morning() throws -> Date {
        try #require(ISO8601DateFormatter().date(from: "2026-08-14T01:39:00Z"))
    }

    @Test("A glyph lost from `at` cannot turn a reset into next year")
    func rejectsResetWithDamagedAtKeyword() throws {
        // Captured verbatim from a live probe: the repaint dropped the `s` of
        // `Resets` and the `t` of `at`. The old parser read what was left as
        // `Aug 14`, defaulted to midnight, found it already past, and rolled a
        // full year forward — the card then showed a Fable window resetting in
        // 2027 and the stale-window check happily kept it all cycle.
        let output = """
        Current session
        8% used
        Resets 11:40am (Asia/Shanghai)
        Current week (all models)
        60% used
        Resets Aug 14 at 12:59pm (Asia/Shanghai)
        Current week (Fable)
        98% used
        ResetAug 14 a 1pm (Asia/Shanghai)
        """

        let quota = try ClaudeCLIUsageParser.parse(
            Data(output.utf8),
            now: try morning(),
            calendar: try shanghai()
        )
        let fable = try #require(quota.fableWindow)

        #expect(
            quota.secondary?.resetsAt
                == ISO8601DateFormatter().date(from: "2026-08-14T04:59:00Z")
        )
        // Weekly rows share one window, so an unreadable row falls back to the
        // corroborated general reset instead of inventing its own.
        #expect(fable.window.resetsAt == quota.secondary?.resetsAt)
    }

    @Test("A repaint that swallows spaces still yields the real reset")
    func parsesWhitespaceCollapsedReset() throws {
        let output = """
        Current session
        8% used
        Resets11:40am(Asia/Shanghai)
        Current week (all models)
        60% used
        ResetsAug14at1pm(Asia/Shanghai)
        """

        let quota = try ClaudeCLIUsageParser.parse(
            Data(output.utf8),
            now: try morning(),
            calendar: try shanghai()
        )

        #expect(
            quota.primary.resetsAt
                == ISO8601DateFormatter().date(from: "2026-08-14T03:40:00Z")
        )
        #expect(
            quota.secondary?.resetsAt
                == ISO8601DateFormatter().date(from: "2026-08-14T05:00:00Z")
        )
    }

    @Test("One damaged repaint cannot outvote the copies that agree")
    func prefersTheResetRepaintsAgreeOn() throws {
        // The damaged copy is the freshest one, which is exactly the case the
        // old `last` rule got wrong: it published a weekly reset two days late
        // while two other copies of the same screen disagreed.
        let output = """
        Current session
        8% used
        Resets 11:40am
        Current week (all models)
        60% used
        Resets Aug 14 at 1pm
        Current session
        8% used
        Resets 11:40am
        Current week (all models)
        60% used
        Resets Aug 14 at 1pm
        Current session
        8% used
        Resets 11:40am
        Current week (all models)
        60% used
        Resets Aug 16 at 11am
        """

        let quota = try ClaudeCLIUsageParser.parse(
            Data(output.utf8),
            now: try morning(),
            calendar: try shanghai()
        )

        #expect(
            quota.secondary?.resetsAt
                == ISO8601DateFormatter().date(from: "2026-08-14T05:00:00Z")
        )
    }

    @Test("A session reset further out than its own window is discarded")
    func rejectsSessionResetBeyondItsWindow() throws {
        // 21:39 local is twelve hours away at 09:39; a five-hour window cannot
        // stretch there, so the only reading is damage.
        let output = """
        Current session
        8% used
        Resets 9:39pm
        Current week (all models)
        60% used
        Resets Aug 14 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(
            Data(output.utf8),
            now: try morning(),
            calendar: try shanghai()
        )

        #expect(quota.primary.resetsAt == nil)
        #expect(quota.secondary?.resetsAt != nil)
    }

    @Test("A weekly row that lost its date does not fall back to today")
    func rejectsBareClockTimeForTheWeeklyWindow() throws {
        let output = """
        Current session
        8% used
        Resets 11:40am
        Current week (all models)
        60% used
        Resets 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(
            Data(output.utf8),
            now: try morning(),
            calendar: try shanghai()
        )

        #expect(quota.primary.resetsAt != nil)
        #expect(quota.secondary?.resetsAt == nil)
    }
}
