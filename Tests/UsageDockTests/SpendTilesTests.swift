import Foundation
import Testing
@testable import UsageDock

@Suite("Spend tiles and extra usage")
struct SpendTilesTests {
    @Test("Compact USD matches OpenUsage-style tile formatting")
    func compactUSD() {
        #expect(UsageFormatting.compactUSD(118.9) == "$118.90")
        #expect(UsageFormatting.compactUSD(0) == "$0.00")
        #expect(UsageFormatting.compactUSD(2_500) == "$2.5K")
        #expect(UsageFormatting.compactUSD(1_200_000) == "$1.2M")
    }

    @Test("Today comes from daily, yesterday and last-30 from history")
    func tilesComposition() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let todayStart = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: todayStart))
        let earlier = try #require(calendar.date(byAdding: .day, value: -5, to: todayStart))

        let insights = UsageInsights(
            claude: nil,
            codex: nil,
            daily: DailyUsage(
                date: "2026-07-23",
                agents: [
                    .init(id: "claude", tokens: 200_000_000, estimatedCost: 100),
                    .init(id: "codex", tokens: 40_300_000, estimatedCost: 18.9)
                ],
                capturedAt: now
            ),
            history: DailyUsageHistory(
                days: [
                    .init(date: earlier, claudeTokens: 1_000, claudeCost: 1, codexTokens: 0, codexCost: 0),
                    .init(date: yesterday, claudeTokens: 400_000_000, claudeCost: 200, codexTokens: 38_500_000, codexCost: 18.04)
                ],
                capturedAt: now
            )
        )

        let tiles = insights.spendTiles(now: now, calendar: calendar)
        #expect(tiles.map(\.id) == ["today", "yesterday", "last30"])
        #expect(tiles[0].cost == 118.9)
        #expect(tiles[0].tokens == 240_300_000)
        #expect(tiles[1].cost == 218.04)
        #expect(tiles[1].tokens == 438_500_000)
        #expect(tiles[2].cost == 219.04)
        #expect(tiles[2].tokens == 438_501_000)
    }

    @Test("Missing history still yields a today tile; empty data yields none")
    func partialData() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let onlyToday = UsageInsights(
            claude: nil,
            codex: nil,
            daily: DailyUsage(date: "d", agents: [.init(id: "claude", tokens: 5, estimatedCost: 1)], capturedAt: now),
            history: nil
        )
        #expect(onlyToday.spendTiles(now: now).map(\.id) == ["today"])

        let empty = UsageInsights(claude: nil, codex: nil, daily: nil, history: nil)
        #expect(empty.spendTiles(now: now).isEmpty)
        #expect(empty.dailyTokenTrend.isEmpty)
    }

    @Test("Claude extra_usage parses spent credits and optional monthly cap")
    func extraUsageParsing() throws {
        let payload = """
        {
          "five_hour": {"utilization": 10},
          "extra_usage": {"is_enabled": true, "used_credits": 36404, "monthly_limit": 50000}
        }
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        #expect(quota.extraUsage == ExtraUsage(spentUSD: 364.04, monthlyLimitUSD: 500))

        #expect(ClaudeOAuthUsageParser.extraUsage(["is_enabled": false, "used_credits": 100]) == nil)
        #expect(ClaudeOAuthUsageParser.extraUsage(["is_enabled": true, "used_credits": 0]) == nil)
        #expect(ClaudeOAuthUsageParser.extraUsage(
            ["is_enabled": true, "used_credits": 1250]
        ) == ExtraUsage(spentUSD: 12.5, monthlyLimitUSD: nil))
    }
}
