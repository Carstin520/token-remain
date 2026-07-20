import SwiftUI

/// Today's ccusage totals: cost, per-provider token split and total tokens.
/// All values are real; before ccusage returns it shows a reading state.
struct LocalUsageCard: View {
    let insights: UsageInsights
    @ObservedObject var layout: PopoverLayoutStore
    @Binding var draggingWidget: PopoverWidget?

    @State private var hoveredProviderID: String?

    private var entries: [UsageInsights.ProviderUsage] {
        insights.providerUsage.filter { $0.tokens > 0 }
    }

    private var hoveredEntry: UsageInsights.ProviderUsage? {
        entries.first { $0.id == hoveredProviderID }
    }

    var body: some View {
        DashboardCard(padding: 11, cornerRadius: 13) {
            VStack(alignment: .leading, spacing: 7) {
                PopoverWidgetHeader(
                    widget: .localUsage,
                    isExpanded: true,
                    isPinned: false,
                    draggingWidget: $draggingWidget,
                    onToggleExpanded: {},
                    onTogglePinned: {},
                    onHide: { withAnimation(.snappy) { layout.hide(.localUsage) } },
                    onMoveUp: { layout.moveUp(.localUsage) },
                    onMoveDown: { layout.moveDown(.localUsage) }
                ) {
                    if let totalCost = insights.totalCost {
                        Text(L10n.usd(totalCost))
                            .numericFont(12, .bold)
                            .foregroundStyle(DashboardTheme.text)
                    }
                }

                if insights.totalTokens != nil {
                    if entries.isEmpty {
                        Text(L10n.text("usage.provider_breakdown_empty"))
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
                                lineWidth: 7,
                                centerText: ringCenterText,
                                centerCaption: hoveredEntry == nil ? nil : L10n.text("usage.api_cost"),
                                centerTextSize: 9,
                                highlightedSegmentID: hoveredProviderID,
                                onHoverSegment: { hoveredProviderID = $0 }
                            )
                            .frame(width: 52, height: 52)

                            VStack(alignment: .leading, spacing: 2) {
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
                        Text(L10n.text("usage.loading_ccusage"))
                            .font(.system(size: 12))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // RingChart is backed by GeometryReader. Keep the popover widget at
            // its intrinsic content height so the surrounding glass container
            // cannot offer it the remaining vertical space in the ScrollView.
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private var ringCenterText: String? {
        if let hoveredEntry {
            return L10n.usd(hoveredEntry.cost)
        }
        return insights.totalCost.map { L10n.usd($0) }
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
                .numericFont(10)
                .foregroundStyle(DashboardTheme.secondaryText)

            Text(UsageFormatting.percent(insights.tokenShare(for: entry)))
                .numericFont(11, .semibold)
                .foregroundStyle(isHovered ? UsageInsights.color(for: entry.id) : DashboardTheme.text)
                .frame(width: 39, alignment: .trailing)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            isHovered ? DashboardTheme.surface3 : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isInside in
            hoveredProviderID = isInside ? entry.id : nil
        }
        .help(L10n.format(
            "usage.provider_help",
            entry.displayName,
            L10n.usd(entry.cost),
            UsageFormatting.compactNumber(entry.tokens),
            UsageFormatting.percent(insights.tokenShare(for: entry))
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(L10n.format(
            "usage.provider_accessibility",
            UsageFormatting.percent(insights.tokenShare(for: entry)),
            L10n.usd(entry.cost),
            UsageFormatting.compactNumber(entry.tokens)
        ))
    }
}
