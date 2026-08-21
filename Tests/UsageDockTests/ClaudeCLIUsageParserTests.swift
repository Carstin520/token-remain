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
/// 漏判会让探针在登录界面上空转满 30 秒,然后把"账号登出了"报成"读取超时",
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

    @Test("Transport and protocol failures keep the PTY fallback")
    func transportFailuresStillFallBack() {
        // 这些和会话无关,探针仍然是有意义的兜底,不该被短路掉。
        #expect(!ClaudeUsageService.mayReflectSignedOutClaude(.requestFailed(500)))
        #expect(!ClaudeUsageService.mayReflectSignedOutClaude(.invalidResponse))
        #expect(!ClaudeUsageService.mayReflectSignedOutClaude(.rateLimited(retryAfterSeconds: 60)))
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
