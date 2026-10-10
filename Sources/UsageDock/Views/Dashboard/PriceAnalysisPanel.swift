import SwiftUI

/// A reference-price projection, not a replacement billing engine. The helper's
/// total is authoritative, including discounts/tiered rates/custom overrides.
struct ModelPriceAnalysis: Identifiable {
    struct Category: Identifiable {
        let id: String
        let tokens: Int64?
        let price: Double?
        var cost: Double? { tokens.flatMap { count in price.map { Double(count) * $0 } } }
    }
    let id: String
    let agentID: String
    let modelID: String
    let matchedModel: String?
    let categories: [Category]
    let totalCost: Double
    let unpriced: Bool
    let unsplitCacheTokens: Int64
    var otherCost: Double { totalCost - categories.compactMap(\.cost).reduce(0, +) }

    static func make(days: [DailyUsageHistory.Day], agentIDs: Set<String>, prices: [String: CCUsagePricingService.PricingOverride]) -> [Self] {
        struct Accumulator {
            var input: Int64 = 0; var output: Int64 = 0; var cache: Int64 = 0
            var read: Int64? = 0; var creation: Int64? = 0
            var cost: Double = 0; var unpriced = false
        }
        var grouped: [String: [String: Accumulator]] = [:]
        for day in days {
            for agent in day.agents where agentIDs.contains(agent.id.lowercased()) {
                for model in agent.models {
                    var value = grouped[agent.id, default: [:]][model.id, default: Accumulator()]
                    value.input += model.inputTokens; value.output += model.outputTokens; value.cache += model.cacheTokens
                    value.read = DailyUsageHistory.sumKnown(value.read, model.cacheReadTokens)
                    value.creation = DailyUsageHistory.sumKnown(value.creation, model.cacheCreationTokens)
                    value.cost += model.cost
                    value.unpriced = value.unpriced || agent.unpricedModels.contains { $0.lowercased() == model.id.lowercased() }
                        || (model.id == "other" && !agent.unpricedModels.isEmpty)
                    grouped[agent.id, default: [:]][model.id] = value
                }
            }
        }
        return grouped.keys.sorted().flatMap { agent in
            grouped[agent]!.keys.sorted().map { model in
                let usage = grouped[agent]![model]!
                let match = model == "other" ? nil : CCUsagePricingService.matchedPricing(modelName: model, pricingOverrides: prices)
                // Absent cache rates are deliberately unknown, never a made-up
                // zero or a silent fallback with provider-specific semantics.
                let price = match?.price
                return Self(id: agent + ":" + model, agentID: agent, modelID: model,
                    matchedModel: match?.canonicalModel,
                    categories: [
                        Category(id: "input", tokens: usage.input, price: agent == "ollama" ? 0 : price?.inputCostPerToken),
                        Category(id: "output", tokens: usage.output, price: agent == "ollama" ? 0 : price?.outputCostPerToken),
                        Category(id: "read", tokens: usage.read, price: agent == "ollama" ? 0 : price?.cacheReadInputTokenCost),
                        Category(id: "write", tokens: usage.creation, price: agent == "ollama" ? 0 : price?.cacheCreationInputTokenCost)
                    ], totalCost: usage.cost, unpriced: usage.unpriced,
                    unsplitCacheTokens: usage.read == nil || usage.creation == nil ? usage.cache : 0)
            }
        }
    }
}

struct PriceAnalysisPanel: View {
    let days: [DailyUsageHistory.Day]
    let agentIDs: Set<String>
    let snapshot: CCUsagePricingService.AnalysisSnapshot

    private var rows: [ModelPriceAnalysis] { ModelPriceAnalysis.make(days: days, agentIDs: agentIDs, prices: snapshot.prices) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text(L10n.text("prices.title")).font(.system(size: 13, weight: .semibold))
            if let first = days.first, let last = days.last {
                Text("\(UsageTrendChart.fullDayLabel(first.date)) – \(UsageTrendChart.fullDayLabel(last.date))")
                    .font(.system(size: 11)).foregroundStyle(DashboardTheme.secondaryText)
            }
            Text(L10n.text("prices.reference_note"))
                .font(.system(size: 11)).foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                Text("LiteLLM · USD / 1M tokens")
                if let date = snapshot.fetchedAt { Text(date, style: .date); Text(date, style: .time) }
                else { Text(L10n.text("prices.no_table")) }
            }.font(.system(size: 10)).foregroundStyle(DashboardTheme.mutedText)
            if rows.isEmpty {
                Text(L10n.text("trends.model_detail_accumulating")).font(.system(size: 11))
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 9) {
                    Text("\(UsageInsights.displayName(for: row.agentID)) · \(row.modelID)")
                        .font(.system(size: 12, weight: .semibold))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let matched = row.matchedModel, matched != row.modelID {
                        Text(L10n.format("prices.matched", matched)).font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row.categories) { category in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L10n.text("prices." + category.id)).font(.system(size: 11, weight: .medium))
                                Text(category.price.map { dollars($0 * 1_000_000) } ?? L10n.text("prices.unknown"))
                                    .font(.system(size: 11, design: .monospaced))
                                Text(category.tokens.map { UsageFormatting.compactNumber($0) + " tokens" } ?? L10n.text("prices.unsplit"))
                                    .font(.system(size: 10)).foregroundStyle(DashboardTheme.secondaryText)
                                Text(category.cost.map(dollars) ?? "—").font(.system(size: 11, design: .monospaced))
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if row.unsplitCacheTokens > 0 {
                        Text(L10n.format("prices.legacy_cache", UsageFormatting.compactNumber(row.unsplitCacheTokens)))
                            .font(.system(size: 10)).foregroundStyle(DashboardTheme.secondaryText)
                    }
                    HStack(alignment: .top) {
                        Text(L10n.text("prices.total") + ": " + (row.unpriced ? L10n.text("prices.unknown") : dollars(row.totalCost)))
                        Spacer(minLength: 8)
                        Text(L10n.text("prices.other") + ": " + (row.unpriced ? "—" : dollars(row.otherCost)))
                    }.font(.system(size: 11))
                    if row.unpriced { Text(L10n.text("prices.unpriced_note")).font(.system(size: 10)) }
                }
                .padding(12)
                .background(DashboardSurface.surface2, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .foregroundStyle(DashboardTheme.text)
    }

    private func dollars(_ value: Double) -> String {
        // Preserve sub-cent estimates and genuine zero; never turn a missing
        // value into zero. Signed residuals account for overestimation as well.
        String(format: "$%.6f", value == 0 ? 0 : value)
    }
}
