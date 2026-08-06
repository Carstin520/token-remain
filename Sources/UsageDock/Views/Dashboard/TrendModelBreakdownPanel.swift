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
        namedLimit: Int = 5
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
            let displayedModels: [DailyUsageHistory.ModelUsage]
            if tail.isEmpty {
                displayedModels = kept
            } else {
                let firstTail = tail[0]
                let other = tail.dropFirst().reduce(
                    DailyUsageHistory.ModelUsage(
                        id: "other",
                        inputTokens: firstTail.inputTokens,
                        outputTokens: firstTail.outputTokens,
                        cacheTokens: firstTail.cacheTokens,
                        cost: firstTail.cost,
                        constituentCount: firstTail.constituentCount
                    )
                ) { partial, row in
                    DailyUsageHistory.ModelUsage(
                        id: "other",
                        inputTokens: partial.inputTokens + row.inputTokens,
                        outputTokens: partial.outputTokens + row.outputTokens,
                        cacheTokens: partial.cacheTokens + row.cacheTokens,
                        cost: partial.cost + row.cost,
                        constituentCount: partial.constituentCount + row.constituentCount
                    )
                }
                displayedModels = kept + [other]
            }
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
                    constituentCount: model.constituentCount
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
    let onClose: () -> Void

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
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(breakdown.groups) { group in
                            agentGroup(group)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
                .scrollIndicators(.automatic)
            }
        }
        .padding(11)
        .background(DashboardTheme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DashboardTheme.border, lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Capsule().fill(color.opacity(0.78)).frame(width: 3, height: 16)
                Text(row.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
                    .help(row.id)
                Spacer(minLength: 8)
                Text(primaryValue(row))
                    .numericFont(10, .semibold)
                    .foregroundStyle(DashboardTheme.text)
                Text(UsageFormatting.percent(row.share * 100))
                    .numericFont(9, .medium)
                    .foregroundStyle(DashboardTheme.mutedText)
                    .frame(width: 40, alignment: .trailing)
            }
            Text(
                L10n.format(
                    "trends.model_io_format",
                    UsageFormatting.compactNumber(row.inputTokens),
                    UsageFormatting.compactNumber(row.outputTokens),
                    UsageFormatting.compactNumber(row.cacheTokens)
                )
            )
            .numericFont(9)
            .foregroundStyle(DashboardTheme.mutedText)
            .padding(.leading, 11)
        }
        .accessibilityElement(children: .combine)
    }

    private func primaryValue(_ row: TrendDayModelBreakdown.ModelRow) -> String {
        switch metric {
        case .tokens:
            return UsageFormatting.compactNumber(row.totalTokens)
        case .cost:
            return String(format: "$%.2f%@", row.cost, row.isUnpriced ? "*" : "")
        }
    }
}
