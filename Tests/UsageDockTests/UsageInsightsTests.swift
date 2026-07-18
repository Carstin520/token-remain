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

    @Test("Medium and low thresholds map to remaining percentage bands")
    func riskThresholds() {
        #expect(RiskLevel(minRemainingPercent: nil) == .unknown)
        #expect(RiskLevel(minRemainingPercent: 5) == .high)
        #expect(RiskLevel(minRemainingPercent: 25) == .medium)
        #expect(RiskLevel(minRemainingPercent: 60) == .low)
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
