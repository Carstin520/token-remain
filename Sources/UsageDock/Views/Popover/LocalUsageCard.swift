import SwiftUI

/// Today's ccusage totals: cost, per-provider token split and total tokens.
/// All values are real; before ccusage returns it shows a reading state.
struct LocalUsageCard: View {
    let insights: UsageInsights

    @State private var hoveredProviderID: String?

    private var entries: [UsageInsights.ProviderUsage] {
        insights.providerUsage.filter { $0.tokens > 0 }
    }

    private var hoveredEntry: UsageInsights.ProviderUsage? {
        entries.first { $0.id == hoveredProviderID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if insights.totalTokens != nil {
                HStack {
                    Text("今日本地统计")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                    Spacer()
                    Text(String(format: "$%.2f", insights.totalCost ?? 0))
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(DashboardTheme.text)
                }

                if entries.isEmpty {
                    Text("暂无按服务商拆分")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.secondaryText)
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        RingChart(
                            segments: entries.map {
                                RingChart.Segment(
                                    id: $0.id,
                                    value: Double($0.tokens),
                                    color: UsageInsights.color(for: $0.id)
                                )
                            },
                            lineWidth: 9,
                            centerText: ringCenterText,
                            centerCaption: hoveredEntry == nil ? nil : "API 花费",
                            centerTextSize: 11,
                            highlightedSegmentID: hoveredProviderID,
                            onHoverSegment: { hoveredProviderID = $0 }
                        )
                        .frame(width: 70, height: 70)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(entries) { entry in
                                providerRow(entry)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .onHover { isInside in
                        if !isInside {
                            hoveredProviderID = nil
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取 ccusage 本地统计…")
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardTheme.surface2, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var ringCenterText: String? {
        if let hoveredEntry {
            return String(format: "$%.2f", hoveredEntry.cost)
        }
        return nil
    }

    private func providerRow(_ entry: UsageInsights.ProviderUsage) -> some View {
        let isHovered = hoveredProviderID == entry.id
        return HStack(spacing: 6) {
            Circle()
                .fill(UsageInsights.color(for: entry.id))
                .frame(width: 7, height: 7)

            Text(entry.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DashboardTheme.text)

            Spacer(minLength: 6)

            Text(UsageFormatting.compactNumber(entry.tokens))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(DashboardTheme.secondaryText)

            Text(UsageFormatting.percent(insights.tokenShare(for: entry)))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isHovered ? UsageInsights.color(for: entry.id) : DashboardTheme.text)
                .frame(width: 39, alignment: .trailing)
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(
            isHovered ? DashboardTheme.surface3 : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isInside in
            hoveredProviderID = isInside ? entry.id : nil
        }
        .help(
            "\(entry.displayName)：\(String(format: "$%.2f", entry.cost)) API 花费，"
                + "\(UsageFormatting.compactNumber(entry.tokens)) tokens，"
                + "占 \(UsageFormatting.percent(insights.tokenShare(for: entry)))"
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(
            "\(UsageFormatting.percent(insights.tokenShare(for: entry)))，"
                + "\(String(format: "$%.2f", entry.cost)) API 花费，"
                + "\(UsageFormatting.compactNumber(entry.tokens)) tokens"
        )
    }
}
