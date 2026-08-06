import Foundation
import Testing
@testable import UsageDock

@Suite("Usage insights")
struct UsageInsightsTests {
    @Test("Risk follows the scarcest window across providers")
    func riskFollowsScarcestWindow() {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 95, windowMinutes: 10_080, resetsAt: nil),
            planName: "max",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let insights = UsageInsights(claude: claude, codex: nil, daily: nil)

        #expect(insights.minRemainingPercent == 5)
        #expect(insights.riskLevel == .high)
        #expect(insights.constrainingWindow?.windowMinutes == 10_080)
    }

    @Test("Named Claude limits participate in insights without replacing the general week")
    func includesScopedClaudeWindow() throws {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: nil),
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 30, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )
        let windows = UsageInsights(claude: claude, codex: nil, daily: nil).windows

        #expect(windows.count == 3)
        #expect(windows.last?.scopeName == "Fable")
        #expect(windows.last?.id.contains("scope-fable") == true)
    }

    @Test("Scoped model limits stay out of global risk and pace selection")
    func scopedLimitsDoNotDriveGlobalRisk() {
        let codex = ProviderQuota(
            provider: .codex,
            primary: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 30, windowMinutes: 10_080, resetsAt: nil),
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "codex_bengalfox",
                    displayName: "GPT-5.3-Codex-Spark",
                    window: QuotaWindow(usedPercent: 99, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )
        let insights = UsageInsights(claude: nil, codex: codex, daily: nil)

        #expect(insights.windows.count == 3)
        #expect(insights.minRemainingPercent == 70)
        #expect(insights.riskLevel == .low)
        #expect(insights.constrainingWindow?.scopeName == nil)
    }

    @Test("Duplicate scoped windows from an old snapshot appear only once")
    func deduplicatesScopedWindows() {
        let first = ScopedQuotaWindow(
            scopeID: "fable",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 10, windowMinutes: 10_080, resetsAt: nil)
        )
        let latest = ScopedQuotaWindow(
            scopeID: "FABLE",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: nil)
        )
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 5, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [first, latest]
        )

        let windows = UsageInsights(claude: claude, codex: nil, daily: nil).windows

        #expect(windows.count == 2)
        #expect(windows.last?.usedPercent == 20)
    }

    @Test("Summary identifies the provider behind the lowest remaining quota")
    func constrainingProviderIsExplicit() {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 4, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 15, windowMinutes: 10_080, resetsAt: nil),
            planName: nil,
            capturedAt: .now
        )
        let codex = ProviderQuota(
            provider: .codex,
            primary: QuotaWindow(usedPercent: 62, windowMinutes: 10_080, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now
        )
        let insights = UsageInsights(claude: claude, codex: codex, daily: nil)

        #expect(insights.constrainingWindow?.provider == .codex)
        #expect(insights.constrainingWindow?.remainingPercent == 38)
    }

    @Test("Medium and low thresholds map to remaining percentage bands")
    func riskThresholds() {
        #expect(RiskLevel(minRemainingPercent: nil) == .unknown)
        #expect(RiskLevel(minRemainingPercent: 5) == .high)
        #expect(RiskLevel(minRemainingPercent: 25) == .medium)
        #expect(RiskLevel(minRemainingPercent: 60) == .low)
        #expect(RiskLevel(minRemainingPercent: 60, projectedRunOut: true) == .medium)
    }

    @Test("Projected run-out elevates risk before remaining quota is low")
    func projectedRunOutElevatesRisk() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let week: TimeInterval = 7 * 24 * 60 * 60
        let codex = ProviderQuota(
            provider: .codex,
            primary: QuotaWindow(
                usedPercent: 40,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(week * 0.9)
            ),
            secondary: nil,
            planName: "pro",
            capturedAt: now
        )
        let insights = UsageInsights(claude: nil, codex: codex, daily: nil)
        let assessment = try #require(insights.paceAssessment(at: now))

        #expect(insights.minRemainingPercent == 60)
        #expect(insights.riskLevel(at: now) == .medium)
        #expect(assessment.window.provider == .codex)
        #expect(assessment.pace.estimatedRunOutAt == now.addingTimeInterval(90_720))
        #expect(insights.decisionHeadline(at: now) == "当前节奏可能提前用尽")
    }

    @Test("Today's totals and provider split come from ccusage agents")
    func totalsAndSplit() {
        let daily = DailyUsage(
            date: "2026-07-18",
            agents: [
                DailyUsage.Agent(id: "codex", tokens: 100, estimatedCost: 0.5),
                DailyUsage.Agent(id: "claude", tokens: 300, estimatedCost: 1.0)
            ],
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        let insights = UsageInsights(claude: nil, codex: nil, daily: daily)

        #expect(insights.totalTokens == 400)
        #expect(insights.totalCost == 1.5)
        // Highest tokens first.
        #expect(insights.providerUsage.first?.id == "claude")
        #expect(insights.providerUsage.first?.provider == .claude)
        #expect(insights.providerUsage.map { insights.tokenShare(for: $0) } == [75, 25])
        #expect(insights.providerUsage.map { insights.costShare(for: $0) } == [2.0 / 3.0 * 100, 1.0 / 3.0 * 100])
    }

    @Test("No quota yields an unknown, empty state instead of fabricated data")
    func emptyState() {
        let insights = UsageInsights(claude: nil, codex: nil, daily: nil)

        #expect(insights.minRemainingPercent == nil)
        #expect(insights.riskLevel == .unknown)
        #expect(insights.totalTokens == nil)
        #expect(insights.providerUsage.isEmpty)
        #expect(insights.lastUpdated == nil)
    }

    @Test("Zero-token providers report a zero share")
    func zeroTokenShare() throws {
        let daily = DailyUsage(
            date: "2026-07-18",
            agents: [DailyUsage.Agent(id: "codex", tokens: 0, estimatedCost: 0)],
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        let insights = UsageInsights(claude: nil, codex: nil, daily: daily)

        let provider = try #require(insights.providerUsage.first)
        #expect(insights.tokenShare(for: provider) == 0)
        #expect(insights.costShare(for: provider) == 0)
    }

    @Test("Last updated is the most recent capture across sources")
    func lastUpdatedIsNewest() {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let daily = DailyUsage(date: "2026-07-18", agents: [], capturedAt: Date(timeIntervalSince1970: 5_000))
        let insights = UsageInsights(claude: claude, codex: nil, daily: daily)

        #expect(insights.lastUpdated == Date(timeIntervalSince1970: 5_000))
    }
}
