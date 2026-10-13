import SwiftUI

/// Pure projection from one cached ccusage day into the compact, on-demand
/// model detail shown below the existing per-app trend chart.
struct TrendDayModelBreakdown: Equatable {
    struct ModelRow: Identifiable, Equatable {
        let id: String
        let displayName: String
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheTokens: Int64
        let cost: Double
        let share: Double
        let isUnpriced: Bool
        let constituentCount: Int
        /// Measured input/output/cache split for this row.
        let composition: TokenComposition
        /// Locally estimated end-to-end output speed; nil for the merged
        /// `other` row and for models without enough timed responses.
        let tokensPerSecond: Double?

        var totalTokens: Int64 { inputTokens + outputTokens + cacheTokens }
    }

    struct AgentGroup: Identifiable, Equatable {
        let id: String
        let displayName: String
        let rows: [ModelRow]
    }

    let date: Date
    let groups: [AgentGroup]

    static func make(
        day: DailyUsageHistory.Day,
        agentIDs: [String],
        metric: TrendMetric,
        namedLimit: Int = 5,
        throughput: ModelThroughputSnapshot = .empty
    ) -> Self {
        let byID = Dictionary(uniqueKeysWithValues: day.agents.map { ($0.id.lowercased(), $0) })
        let groups = agentIDs.compactMap { requestedID -> AgentGroup? in
            let agentID = requestedID.lowercased()
            guard let agent = byID[agentID], !agent.models.isEmpty else { return nil }
            let unpriced = Set(agent.unpricedModels.map { $0.lowercased() })
            let namedIDs = Set(agent.models.filter { $0.id != "other" }.map { $0.id.lowercased() })

            func isUnpriced(_ model: DailyUsageHistory.ModelUsage) -> Bool {
                if unpriced.contains(model.id.lowercased()) { return true }
                return model.id == "other" && unpriced.contains { !namedIDs.contains($0) }
            }

            let named = agent.models.filter { $0.id != "other" }.sorted { lhs, rhs in
                if metric == .cost {
                    let lhsUnpriced = isUnpriced(lhs)
                    let rhsUnpriced = isUnpriced(rhs)
                    if lhsUnpriced != rhsUnpriced { return !lhsUnpriced }
                    if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
                } else if lhs.totalTokens != rhs.totalTokens {
                    return lhs.totalTokens > rhs.totalTokens
                }
                return lhs.id < rhs.id
            }
            let kept = Array(named.prefix(max(0, namedLimit)))
            let tail = Array(named.dropFirst(max(0, namedLimit)))
                + agent.models.filter { $0.id == "other" }
            let otherIsUnpriced = tail.contains(where: isUnpriced)
            let displayedModels = kept + [DailyUsageHistory.mergedTail(tail)].compactMap { $0 }
            let metricTotal = displayedModels.reduce(0.0) { partial, model in
                partial + (metric == .tokens ? Double(model.totalTokens) : model.cost)
            }
            let rows = displayedModels.map { model in
                let metricValue = metric == .tokens ? Double(model.totalTokens) : model.cost
                return ModelRow(
                    id: model.id,
                    displayName: displayName(for: model),
                    inputTokens: model.inputTokens,
                    outputTokens: model.outputTokens,
                    cacheTokens: model.cacheTokens,
                    cost: model.cost,
                    share: metricTotal > 0 ? metricValue / metricTotal : 0,
                    isUnpriced: model.id == "other" ? otherIsUnpriced : isUnpriced(model),
                    constituentCount: model.constituentCount,
                    composition: TokenComposition(model: model),
                    tokensPerSecond: model.id == "other"
                        ? nil
                        : throughput.tokensPerSecond(day: day.date, agentID: agentID, modelID: model.id)
                )
            }
            return AgentGroup(
                id: agentID,
                displayName: UsageInsights.displayName(for: agentID),
                rows: rows
            )
        }
        return Self(date: day.date, groups: groups)
    }

    private static func displayName(for model: DailyUsageHistory.ModelUsage) -> String {
        if model.id == "other" {
            return L10n.format("trends.model_other_format", model.constituentCount)
        }
        let raw = model.id
        let withoutClaude = raw.hasPrefix("claude-") ? String(raw.dropFirst("claude-".count)) : raw
        guard withoutClaude.count > 28 else { return withoutClaude }
        return String(withoutClaude.prefix(27)) + "…"
    }
}

struct TrendModelBreakdownPanel: View {
    let breakdown: TrendDayModelBreakdown
    let metric: TrendMetric
    var currency: CurrencyDisplay = .usd
    let onClose: () -> Void

    private var showsThroughputNote: Bool {
        breakdown.groups.contains { group in group.rows.contains { $0.tokensPerSecond != nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(UsageTrendChart.fullDayLabel(breakdown.date))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                TagPill(text: L10n.text("trends.model_detail_tag"), color: DashboardTheme.violet)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DashboardTheme.secondaryText)
                .help(L10n.text("action.close"))
            }

            if breakdown.groups.isEmpty {
                Text(L10n.text("trends.model_detail_accumulating"))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.mutedText)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                // Two apps with three models each fit without an inner
                // scroll; only unusually long model lists scroll (DB-002).
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(breakdown.groups) { group in
                            agentGroup(group)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .scrollIndicators(.automatic)

                if showsThroughputNote {
                    Text(L10n.text("trends.model_tps_note"))
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(11)
        .background(DashboardSurface.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DashboardSurface.border, lineWidth: 1)
        )
    }

    private func agentGroup(_ group: TrendDayModelBreakdown.AgentGroup) -> some View {
        let color = UsageTrendChart.color(forAgentID: group.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 10, height: 6)
                Text(group.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            ForEach(group.rows) { row in
                modelRow(row, color: color)
            }
        }
    }

    private func modelRow(_ row: TrendDayModelBreakdown.ModelRow, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Capsule().fill(color.opacity(0.78)).frame(width: 3, height: 16)
                Text(row.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
                    .help(row.id)
                if let tokensPerSecond = row.tokensPerSecond {
                    Text(L10n.format("trends.model_tps_format", Self.speedLabel(tokensPerSecond)))
                        .numericFont(10, .medium)
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DashboardSurface.surface3, in: Capsule())
                        .help(L10n.text("trends.model_tps_help"))
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Text(primaryValue(row))
                    .numericFont(11, .semibold)
                    .foregroundStyle(DashboardTheme.text)
                Text(UsageFormatting.percent(row.share * 100))
                    .numericFont(10)
                    .foregroundStyle(DashboardTheme.mutedText)
                    .frame(width: 42, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 3) {
                TokenCompositionBar(composition: row.composition, height: 3)
                    .help(Self.compositionHelp(row.composition))
                Text(ioLine(row))
                    .numericFont(10)
                    .foregroundStyle(DashboardTheme.mutedText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 11)
        }
        .accessibilityElement(children: .combine)
    }

    private func ioLine(_ row: TrendDayModelBreakdown.ModelRow) -> String {
        let composition = row.composition
        guard composition.cacheUnsplit == 0 else {
            return L10n.format(
                "trends.model_io_format",
                UsageFormatting.compactNumber(row.inputTokens),
                UsageFormatting.compactNumber(row.outputTokens),
                UsageFormatting.compactNumber(row.cacheTokens)
            )
        }
        return L10n.format(
            "trends.model_io_split_format",
            UsageFormatting.compactNumber(composition.input),
            UsageFormatting.compactNumber(composition.output),
            UsageFormatting.compactNumber(composition.cacheWrite),
            UsageFormatting.compactNumber(composition.cacheRead)
        )
    }

    static func compositionHelp(_ composition: TokenComposition) -> String {
        composition.parts
            .map { "\($0.kind.label) \(TokenCompositionStrip.shareLabel($0.share))" }
            .joined(separator: " · ")
    }

    static func speedLabel(_ tokensPerSecond: Double) -> String {
        tokensPerSecond >= 100
            ? String(format: "%.0f", tokensPerSecond)
            : String(format: "%.1f", tokensPerSecond)
    }

    private func primaryValue(_ row: TrendDayModelBreakdown.ModelRow) -> String {
        switch metric {
        case .tokens:
            return UsageFormatting.compactNumber(row.totalTokens)
        case .cost:
            return currency.amount(usd: row.cost) + (row.isUnpriced ? "*" : "")
        }
    }
}
