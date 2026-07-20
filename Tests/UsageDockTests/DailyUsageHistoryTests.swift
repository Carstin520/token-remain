import Foundation
import Testing
@testable import UsageDock

@Suite("Daily usage history")
struct DailyUsageHistoryTests {
    private func payload(_ rows: String) -> Data {
        Data("{\"daily\":[\(rows)]}".utf8)
    }

    @Test("Parses per-day Claude / Codex split from ccusage by-agent JSON")
    func parsesSplit() throws {
        let data = payload("""
        {"period":"2026-07-18","agents":[
            {"agent":"claude","totalTokens":300,"totalCost":1.5},
            {"agent":"codex","totalTokens":100,"totalCost":0.5}
        ]},
        {"period":"2026-07-19","agents":[
            {"agent":"codex","totalTokens":250,"totalCost":2.0},
            {"agent":"claude","totalTokens":50,"totalCost":0.25}
        ]}
        """)

        let history = try CCUsageService.parseHistory(data)
        #expect(history.days.count == 2)

        // Oldest-first ordering regardless of input / agent order.
        let first = history.days[0]
        #expect(first.claudeTokens == 300)
        #expect(first.codexTokens == 100)
        #expect(first.totalTokens == 400)
        #expect(first.totalCost == 2.0)

        let second = history.days[1]
        #expect(second.claudeTokens == 50)
        #expect(second.codexTokens == 250)
        #expect(second.date > first.date)
    }

    @Test("A provider absent on a day defaults to zero, no fabricated value")
    func absentProviderIsZero() throws {
        let data = payload("""
        {"period":"2026-07-20","agents":[
            {"agent":"claude","totalTokens":500,"totalCost":3.0}
        ]}
        """)

        let day = try #require(try CCUsageService.parseHistory(data).days.first)
        #expect(day.claudeTokens == 500)
        #expect(day.codexTokens == 0)
        #expect(day.codexCost == 0)
        #expect(day.tokens(for: .codex) == 0)
        #expect(day.cost(for: .claude) == 3.0)
    }

    @Test("Trend provider selection supports both, either, and neither series")
    func selectedTrendTotals() throws {
        let data = payload("""
        {"period":"2026-07-20","agents":[
            {"agent":"claude","totalTokens":300,"totalCost":1.5},
            {"agent":"codex","totalTokens":100,"totalCost":0.5}
        ]}
        """)
        let day = try #require(try CCUsageService.parseHistory(data).days.first)

        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .tokens,
            visibleProviders: [.claude, .codex]
        ) == 400)
        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .tokens,
            visibleProviders: [.codex]
        ) == 100)
        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .cost,
            visibleProviders: [.claude]
        ) == 1.5)
        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .tokens,
            visibleProviders: []
        ) == 0)
    }

    @Test("Rows with unparseable periods are dropped rather than guessed")
    func dropsBadPeriods() throws {
        let data = payload("""
        {"period":"not-a-date","agents":[{"agent":"claude","totalTokens":1,"totalCost":0.1}]},
        {"period":"2026-07-20","agents":[{"agent":"claude","totalTokens":2,"totalCost":0.2}]}
        """)

        let history = try CCUsageService.parseHistory(data)
        #expect(history.days.count == 1)
        #expect(history.days.first?.claudeTokens == 2)
    }

    @Test("Nice axis ceiling rounds a peak up to 1/2/2.5/5/10 x 10^n")
    func niceCeiling() {
        #expect(UsageTrendChart.niceCeiling(0) == 1)
        #expect(UsageTrendChart.niceCeiling(1_200_000) == 2_000_000)
        #expect(UsageTrendChart.niceCeiling(4.5) == 5)
        #expect(UsageTrendChart.niceCeiling(2.3) == 2.5)
        #expect(UsageTrendChart.niceCeiling(900) == 1_000)
    }

    @Test("Compact axis token labels stay short enough for the y gutter")
    func compactAxisTokens() {
        #expect(UsageTrendChart.compactAxisTokens(1_000_000_000) == "1.0B")
        #expect(UsageTrendChart.compactAxisTokens(750_000_000) == "750M")
        #expect(UsageTrendChart.compactAxisTokens(1_200_000) == "1.2M")
        #expect(UsageTrendChart.compactAxisTokens(500_000) == "500K")
        #expect(UsageTrendChart.compactAxisTokens(250) == "250")
    }

    @Test("Day labels read in month/day form")
    func dayLabels() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 9
        let date = Calendar.current.date(from: components)!
        #expect(UsageTrendChart.dayMonthLabel(date) == "7/9")
        #expect(UsageTrendChart.fullDayLabel(date) == "7月9日")
    }
}
