import Foundation
import Testing
@testable import UsageDock

@Suite("Token composition")
struct TokenCompositionTests {
    @Test("ccusage cache creation and cache read stay separate per model")
    func parsesCacheSplit() throws {
        let data = Data("""
        {"daily":[{"period":"2026-10-04","agents":[{
            "agent":"claude","totalTokens":1111,"totalCost":1.0,
            "modelBreakdowns":[{"modelName":"claude-opus-5-5","cost":1.0,
                "inputTokens":1,"outputTokens":10,"cacheCreationTokens":100,"cacheReadTokens":1000}]
        }]}]}
        """.utf8)

        let history = try CCUsageService.parseHistory(data)
        let model = try #require(history.days.first?.agents.first?.models.first)
        #expect(model.cacheTokens == 1_100)
        #expect(model.cacheWriteTokens == 100)
        #expect(model.cacheReadTokens == 1_000)
        #expect(model.totalTokens == 1_111)
    }

    @Test("A cache written before the split decodes as one unsplit cache total")
    func decodesLegacyCacheRow() throws {
        let legacy = Data("""
        {"id":"gpt-6-astra","inputTokens":4,"outputTokens":2,"cacheTokens":90,"cost":0.5}
        """.utf8)
        let model = try JSONDecoder().decode(DailyUsageHistory.ModelUsage.self, from: legacy)
        #expect(model.cacheTokens == 90)
        #expect(model.cacheWriteTokens == nil)
        #expect(model.cacheReadTokens == nil)

        let composition = TokenComposition(model: model)
        #expect(composition.cacheUnsplit == 90)
        #expect(composition.parts.map(\.kind) == [.input, .output, .cacheWrite, .cacheRead, .cacheUnsplit])
    }

    @Test("The split round-trips through the history cache")
    func roundTripsSplit() throws {
        let model = DailyUsageHistory.ModelUsage(
            id: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 7, cost: 0,
            cacheWriteTokens: 3, cacheReadTokens: 4
        )
        let decoded = try JSONDecoder().decode(
            DailyUsageHistory.ModelUsage.self,
            from: JSONEncoder().encode(model)
        )
        #expect(decoded == model)
        #expect(decoded.cacheWriteTokens == 3)
    }

    @Test("An inconsistent split is dropped rather than trusted")
    func rejectsInconsistentSplit() {
        let model = DailyUsageHistory.ModelUsage(
            id: "m", inputTokens: 0, outputTokens: 0, cacheTokens: 10, cost: 0,
            cacheWriteTokens: 3, cacheReadTokens: 4
        )
        #expect(model.cacheWriteTokens == nil)
        #expect(model.cacheReadTokens == nil)
    }

    @Test("Merging keeps the split only when every row carries it")
    func mergeKeepsOrDropsSplit() {
        let split = DailyUsageHistory.ModelUsage(
            id: "a", inputTokens: 1, outputTokens: 1, cacheTokens: 5, cost: 0,
            cacheWriteTokens: 2, cacheReadTokens: 3
        )
        let alsoSplit = DailyUsageHistory.ModelUsage(
            id: "A", inputTokens: 1, outputTokens: 1, cacheTokens: 5, cost: 0,
            cacheWriteTokens: 1, cacheReadTokens: 4
        )
        let unsplit = DailyUsageHistory.ModelUsage(
            id: "a", inputTokens: 0, outputTokens: 0, cacheTokens: 6, cost: 0
        )

        let merged = DailyUsageHistory.boundedModels([split, alsoSplit])
        #expect(merged.count == 1)
        #expect(merged[0].cacheWriteTokens == 3)
        #expect(merged[0].cacheReadTokens == 7)

        let mixed = DailyUsageHistory.boundedModels([split, unsplit])
        #expect(mixed[0].cacheTokens == 11)
        #expect(mixed[0].cacheWriteTokens == nil)
    }

    @Test("Composition sums visible agents only and shares add to one")
    func compositionAcrossDays() {
        let model = DailyUsageHistory.ModelUsage(
            id: "m", inputTokens: 10, outputTokens: 30, cacheTokens: 60, cost: 0,
            cacheWriteTokens: 20, cacheReadTokens: 40
        )
        let day = DailyUsageHistory.Day(
            date: Date(timeIntervalSince1970: 0),
            agents: [
                .init(id: "claude", tokens: 100, cost: 0, models: [model]),
                .init(id: "codex", tokens: 100, cost: 0, models: [model])
            ]
        )
        let composition = TokenComposition(days: [day, day], agentIDs: ["claude"])
        #expect(composition.total == 200)
        #expect(composition.input == 20)
        #expect(composition.cacheRead == 80)
        let shares = composition.parts.map(\.share)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
        #expect(composition.parts.count == 4)
    }

    @Test("Bar widths keep tiny shares visible without overflowing")
    func barWidthsFloorTinyShares() {
        let widths = TokenCompositionBar.widths(
            for: [0.001, 0.004, 0.995],
            available: 200,
            minimum: 2
        )
        #expect(widths[0] == 2)
        #expect(widths[1] == 2)
        #expect(abs(widths.reduce(0, +) - 200) < 0.001)
        #expect(TokenCompositionStrip.shareLabel(0.0004) == "<0.1%")
        #expect(TokenCompositionStrip.shareLabel(0.949) == "94.9%")
    }

    @Test("Model breakdown carries composition and local speed per named row")
    func breakdownRowsCarryCompositionAndSpeed() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        let model = DailyUsageHistory.ModelUsage(
            id: "gpt-6-astra", inputTokens: 4, outputTokens: 1, cacheTokens: 5, cost: 1,
            cacheWriteTokens: 0, cacheReadTokens: 5
        )
        let day = DailyUsageHistory.Day(
            date: date,
            agents: [.init(id: "codex", tokens: 10, cost: 1, models: [model])]
        )
        let key = ModelThroughputSnapshot.key(
            day: ModelThroughputParser.dayKey(date),
            agentID: "codex",
            modelID: "gpt-6-astra"
        )
        let throughput = ModelThroughputSnapshot(
            buckets: [key: ThroughputBucket(outputTokens: 600, seconds: 10, samples: 4)]
        )
        let breakdown = TrendDayModelBreakdown.make(
            day: day,
            agentIDs: ["codex"],
            metric: .tokens,
            throughput: throughput
        )
        let row = try #require(breakdown.groups.first?.rows.first)
        #expect(row.tokensPerSecond == 60)
        #expect(row.composition.cacheRead == 5)
        #expect(row.composition.output == 1)
    }
}
