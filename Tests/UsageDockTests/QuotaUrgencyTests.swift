import Foundation
import Testing
@testable import UsageDock

@Suite("Quota urgency")
struct QuotaUrgencyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A window `elapsed` minutes into its cycle with `used` percent spent.
    private func window(
        used: Double,
        minutes: Int,
        elapsed: Double,
        pool: String? = nil
    ) -> QuotaWindow {
        var window = QuotaWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: now.addingTimeInterval((Double(minutes) - elapsed) * 60)
        )
        window.poolName = pool
        return window
    }

    /// Codex 7 d is ahead of pace and runs out before reset; Claude's 7 d is
    /// the lowest but lasts; Cursor has two pools; Antigravity is a day old.
    private var quotas: [ProviderQuota] {
        [
            ProviderQuota(
                provider: .claude,
                primary: window(used: 2, minutes: 300, elapsed: 2),
                secondary: window(used: 16, minutes: 10_080, elapsed: 5_000),
                planName: "pro",
                capturedAt: now
            ),
            ProviderQuota(
                provider: .codex,
                primary: window(used: 14, minutes: 10_080, elapsed: 1_000),
                secondary: nil,
                planName: "prolite",
                capturedAt: now
            ),
            ProviderQuota(
                provider: .cursor,
                primary: window(used: 12.5, minutes: 44_640, elapsed: 7_000, pool: "Other Models"),
                secondary: window(used: 0, minutes: 44_640, elapsed: 7_000, pool: "Cursor Models"),
                planName: "pro_plus",
                capturedAt: now
            ),
            ProviderQuota(
                provider: .antigravity,
                primary: window(used: 0, minutes: 10_080, elapsed: 3_000),
                secondary: nil,
                planName: nil,
                capturedAt: now.addingTimeInterval(-86_400)
            ),
        ]
    }

    private var insights: UsageInsights {
        UsageInsights(claude: nil, codex: nil, others: quotas, daily: nil)
    }

    @Test("Only windows projected to run out before reset count as at risk")
    func projectedRunOutsNameTheAheadWindow() {
        let runOuts = insights.projectedRunOuts(at: now)

        #expect(runOuts.map(\.window.provider) == [.codex])
        #expect(runOuts.first?.window.windowMinutes == 10_080)
        // The headline assessment and the count agree on the same window.
        #expect(insights.paceAssessment(at: now)?.window.id == runOuts.first?.window.id)
    }

    @Test("A used-up window is the most urgent and reports exhausted, not a projection")
    func exhaustedWindowLeads() throws {
        let codex = ProviderQuota(
            provider: .codex,
            primary: window(used: 100, minutes: 10_080, elapsed: 2_000),
            secondary: window(used: 0, minutes: 300, elapsed: 0.5),
            planName: "plus",
            capturedAt: now
        )
        let insights = UsageInsights(claude: nil, codex: nil, others: quotas.filter { $0.provider != .codex } + [codex], daily: nil)
        let assessment = try #require(insights.paceAssessment(at: now))

        #expect(assessment.window.provider == .codex)
        #expect(assessment.pace.isExhausted)
        #expect(insights.projectedRunOuts(at: now).map(\.window.provider) == [.codex])
    }

    @Test("Groups list each provider once, at-risk first and stale data last")
    func groupsSortByUrgency() {
        let groups = QuotaWindowTable.groups(
            quotas: quotas,
            notices: [:],
            refreshInterval: 300,
            now: now
        )

        #expect(groups.map(\.provider) == [.codex, .claude, .cursor, .antigravity])
        #expect(groups.first?.rows.first?.runsOutBeforeReset == true)
        #expect(groups.last?.attention != nil)
        #expect(groups.dropLast().allSatisfy { $0.attention == nil })
    }

    @Test("Rows keep a fixed shortest-window-first order, pools stay in one group")
    func rowsSortInsideAGroup() throws {
        let groups = QuotaWindowTable.groups(quotas: quotas, notices: [:], refreshInterval: 300, now: now)
        let claude = try #require(groups.first { $0.provider == .claude })
        let cursor = try #require(groups.first { $0.provider == .cursor })

        // Claude's 7 d has less left than its 5 hr, yet 5 hr stays on top.
        #expect(claude.rows.map(\.window.windowMinutes) == [300, 10_080])
        #expect(cursor.rows.count == 2)
        #expect(cursor.rows.map(\.window.poolName) == ["Other Models", "Cursor Models"])
    }

    @Test("A used-up 7 d still sits below 5 hr, and its provider still leads")
    func usedUpWindowKeepsItsRow() throws {
        let codex = ProviderQuota(
            provider: .codex,
            primary: window(used: 100, minutes: 10_080, elapsed: 2_000),
            secondary: window(used: 0, minutes: 300, elapsed: 0.5),
            planName: "plus",
            capturedAt: now
        )
        let groups = QuotaWindowTable.groups(
            quotas: quotas.filter { $0.provider != .codex } + [codex],
            notices: [:],
            refreshInterval: 300,
            now: now
        )
        let first = try #require(groups.first)

        #expect(first.provider == .codex)
        #expect(first.rows.map(\.window.windowMinutes) == [300, 10_080])
        #expect(first.rows.last?.runsOutBeforeReset == true)
    }

    @Test("A shared pool moves to the group; differing pools stay on their rows")
    func sharedQualifierIsSaidOnce() throws {
        let gemini = ProviderQuota(
            provider: .antigravity,
            primary: window(used: 0, minutes: 300, elapsed: 60, pool: "Gemini"),
            secondary: window(used: 0, minutes: 10_080, elapsed: 60, pool: "Gemini"),
            planName: nil,
            capturedAt: now
        )
        let groups = QuotaWindowTable.groups(
            quotas: quotas.filter { $0.provider != .antigravity } + [gemini],
            notices: [:],
            refreshInterval: 300,
            now: now
        )
        let cursor = try #require(groups.first { $0.provider == .cursor })
        let antigravity = try #require(groups.first { $0.provider == .antigravity })

        #expect(antigravity.qualifier == "Gemini")
        #expect(antigravity.rows.allSatisfy { !$0.label.contains("Gemini") })
        #expect(cursor.qualifier == nil)
        #expect(cursor.rows.allSatisfy { $0.label.contains("Models") })
    }

    @Test("Plan badges follow the subscription card in catalog names")
    func planLabelsFollowSubscriptionCard() {
        let accounts = quotas.map {
            SubscriptionAccountInput(accountID: .system($0.provider), provider: $0.provider, accountName: "", quota: $0)
        }
        func labels(
            _ accounts: [SubscriptionAccountInput],
            _ overrides: [ProviderAccountID: SubscriptionPriceOverride] = [:]
        ) -> [ProviderQuota.Provider: String?] {
            let plans = QuotaWindowTable.planLabels(
                from: SubscriptionCostSummary.make(accounts: accounts, overrides: overrides, rates: nil)
            )
            let groups = QuotaWindowTable.groups(
                quotas: quotas, notices: [:], plans: plans, refreshInterval: 300, now: now
            )
            return Dictionary(uniqueKeysWithValues: groups.map { ($0.provider, $0.planLabel) })
        }

        let detected = labels(accounts)
        #expect(detected[.cursor] == "Pro+")
        #expect(detected[.codex] == "Pro 5x")
        #expect(detected[.claude] == "Pro")
        #expect(detected[.antigravity] == .some(nil))

        // A tier chosen on the card replaces the detected one in the table too.
        let chosen = labels(accounts, [
            .system(.claude): SubscriptionPriceOverride(planID: "claude.max20x", currencyCode: "USD", excludesFromTotal: false),
            .system(.antigravity): SubscriptionPriceOverride(planID: "antigravity.aipro", currencyCode: "USD", excludesFromTotal: false),
        ])
        #expect(chosen[.claude] == "Ultra")
        #expect(chosen[.antigravity] == "Google AI Pro")

        // Two accounts on different tiers: the one row set cannot name either.
        var work = quotas[1]
        work = ProviderQuota(provider: .codex, primary: work.primary, secondary: nil, planName: "plus", capturedAt: now)
        let split = labels(accounts + [
            SubscriptionAccountInput(accountID: .managed(UUID()), provider: .codex, accountName: "Work", quota: work),
        ])
        #expect(split[.codex] == .some(nil))
    }

    @Test("Staleness needs a refresh cycle; notices always count")
    func attentionRules() {
        #expect(QuotaWindowTable.staleThreshold(refreshInterval: nil) == nil)
        #expect(QuotaWindowTable.staleThreshold(refreshInterval: 60) == 600)
        #expect(QuotaWindowTable.staleThreshold(refreshInterval: 1_800) == 3_600)

        let manual = QuotaWindowTable.attentionProviders(
            quotas: quotas, notices: [:], refreshInterval: nil, now: now
        )
        #expect(manual.isEmpty)

        let automatic = QuotaWindowTable.attentionProviders(
            quotas: quotas,
            notices: [.devin: "Sign in to Devin"],
            refreshInterval: 300,
            now: now
        )
        #expect(Set(automatic) == [.antigravity, .devin])
    }

    @Test("Resets inside a day read as an h:mm clock, later ones as a countdown")
    func resetClockThreshold() {
        #expect(QuotaWindowsPanel.showsResetClock(now.addingTimeInterval(60), now: now))
        #expect(QuotaWindowsPanel.showsResetClock(now.addingTimeInterval(86_399), now: now))
        #expect(!QuotaWindowsPanel.showsResetClock(now.addingTimeInterval(86_400), now: now))
        #expect(!QuotaWindowsPanel.showsResetClock(now, now: now))
        #expect(!QuotaWindowsPanel.showsResetClock(now.addingTimeInterval(-60), now: now))

        // Inside a day the clock reads h:mm and only changes by the minute;
        // per-second ticking is left to the final hour.
        #expect(QuotaWindowsPanel.resetCountdown(now.addingTimeInterval(4 * 3_600 + 59 * 60 + 53), now: now) == "4:59")
        #expect(QuotaWindowsPanel.resetCountdown(now.addingTimeInterval(3_600), now: now) == "1:00")
        #expect(UsageFormatting.showsLiveSecondCountdown(to: now.addingTimeInterval(3_599), now: now))
        #expect(!UsageFormatting.showsLiveSecondCountdown(to: now.addingTimeInterval(3_600), now: now))
        #expect(QuotaWindowsPanel.wholeSecond(Date(timeIntervalSinceReferenceDate: 10.2))
            == Date(timeIntervalSinceReferenceDate: 11))
    }
}
