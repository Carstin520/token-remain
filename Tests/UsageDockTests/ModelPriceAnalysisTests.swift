import Foundation
import Testing
@testable import UsageDock

@Suite("Model price analysis")
struct ModelPriceAnalysisTests {
    static let price = CCUsagePricingService.PricingOverride(
        inputCostPerToken: 0.000005, outputCostPerToken: 0.000025,
        cacheCreationInputTokenCost: 0.00000625, cacheReadInputTokenCost: 0.0000005,
        inputCostPerTokenAbove200kTokens: nil, outputCostPerTokenAbove200kTokens: nil,
        cacheCreationInputTokenCostAbove200kTokens: nil, cacheReadInputTokenCostAbove200kTokens: nil,
        maxInputTokens: nil, fastMultiplier: nil)

    static func day(cost: Double = 0.025, read: Int64? = 300, write: Int64? = 100) -> DailyUsageHistory.Day {
        .init(date: .now, agents: [.init(id: "claude", tokens: 1000, cost: cost, models: [
            .init(id: "claude-fixture", inputTokens: 200, outputTokens: 400, cacheTokens: 400, cost: cost,
                  cacheReadTokens: read, cacheCreationTokens: write)
        ])])
    }

    @Test(arguments: [0.025, 0.001]) func reconcilesPositiveAndNegativeResiduals(cost: Double) throws {
        let row = try #require(ModelPriceAnalysis.make(days: [Self.day(cost: cost)], agentIDs: ["claude"], prices: ["claude-fixture": Self.price]).first)
        #expect(row.categories.map(\.tokens) == [200, 400, 300, 100])
        let sum = row.categories.compactMap(\.cost).reduce(0, +)
        #expect(abs(sum + row.otherCost - cost) < 0.000000001)
        #expect((row.otherCost > 0) == (cost == 0.025))
    }

    @Test func oldHistoryRemainsUnsplitAndDecodesWithOriginalTotal() throws {
        let old = Data(#"{"id":"claude-fixture","inputTokens":200,"outputTokens":400,"cacheTokens":400,"cost":0.025}"#.utf8)
        let model = try JSONDecoder().decode(DailyUsageHistory.ModelUsage.self, from: old)
        #expect(model.totalTokens == 1000)
        #expect(model.cacheReadTokens == nil)
        #expect(model.cacheCreationTokens == nil)
        let day = Self.day(read: nil, write: nil)
        let row = try #require(ModelPriceAnalysis.make(days: [day], agentIDs: ["claude"], prices: ["claude-fixture": Self.price]).first)
        #expect(row.unsplitCacheTokens == 400)
        #expect(row.categories[2].cost == nil)
        let encoded = try JSONEncoder().encode(Self.day().agents[0].models[0])
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["cacheTokens"] as? Int == 400) // older readers still receive their aggregate
        #expect(try JSONDecoder().decode(DailyUsageHistory.ModelUsage.self, from: encoded).cacheReadTokens == 300)
    }

    @Test func aggregationPreservesKnownSplitsAndDoesNotInventOldSplits() throws {
        let first = Self.day().agents[0].models[0]
        let merged = try #require(DailyUsageHistory.boundedModels([first, first]).first)
        #expect(merged.cacheReadTokens == 600)
        #expect(merged.cacheCreationTokens == 200)
        let old = Self.day(read: nil, write: nil).agents[0].models[0]
        #expect(DailyUsageHistory.boundedModels([old, first]).first?.cacheReadTokens == nil)
        #expect(DailyUsageHistory.boundedModels([first, old]).first?.cacheReadTokens == nil)
    }

    @Test func missingRatesStayUnknownWhileExplicitFreeRatesStayZero() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.price)) as? [String: Any])
        object.removeValue(forKey: "cacheReadInputTokenCost")
        object["inputCostPerToken"] = 0
        let price = try JSONDecoder().decode(CCUsagePricingService.PricingOverride.self, from: JSONSerialization.data(withJSONObject: object))
        let row = try #require(ModelPriceAnalysis.make(days: [Self.day()], agentIDs: ["claude"], prices: ["claude-fixture": price]).first)
        #expect(row.categories[0].price == 0)
        #expect(row.categories[2].price == nil)
        #expect(row.categories[2].cost == nil)
        #expect(ModelPriceAnalysis.make(days: [Self.day()], agentIDs: [], prices: [:]).isEmpty)
    }

    @Test func readingAnalysisNeverRequestsPrices() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = CCUsagePricingService(cacheDirectory: directory) { _ in
            Issue.record("Viewing prices must not issue a network request")
            throw URLError(.unknown)
        }
        let snapshot = await service.cachedAnalysisSnapshot()
        #expect(snapshot.prices.isEmpty)
        #expect(snapshot.fetchedAt == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
