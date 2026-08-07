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
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-17T10:00:00Z"))
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

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

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
