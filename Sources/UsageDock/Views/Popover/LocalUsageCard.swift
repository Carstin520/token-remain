import SwiftUI

/// Today's ccusage totals: cost, per-provider token split and total tokens.
/// All values are real; before ccusage returns it shows a reading state.
struct LocalUsageCard: View {
    let insights: UsageInsights
    let localUsageStatus: UsageStore.LocalUsageStatus
    let isRefreshing: Bool
    let onRetry: () -> Void
    @ObservedObject var layout: PopoverLayoutStore

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
                    onToggleExpanded: {},
                    onTogglePinned: {},
                    onHide: { withAnimation(.snappy) { layout.hide(.localUsage) } },
                    onMoveUp: { layout.moveUp(.localUsage) },
                    onMoveDown: { layout.moveDown(.localUsage) }
                ) {
                    if let totalCost = insights.totalCost {
                        Text(L10n.usd(totalCost))
                            .numericFont(15, .bold)
                            .foregroundStyle(DashboardTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .layoutPriority(1)
                    } else if !insights.unpricedModels.isEmpty {
                        Text(L10n.text("usage.price_unavailable"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DashboardTheme.warning)
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
                                lineWidth: 8,
                                centerText: ringCenterText,
                                centerCaption: ringCenterCaption,
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
                    if !insights.unpricedModels.isEmpty {
                        Label(
                            L10n.format(
                                "usage.unpriced_models_format",
                                insights.unpricedModels.joined(separator: L10n.text("common.list_separator"))
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(DashboardTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    localUsageEmptyState
                }

                spendTilesSection
            }
            // RingChart is backed by GeometryReader. Keep the popover widget at
            // its intrinsic content height so the surrounding glass container
            // cannot offer it the remaining vertical space in the ScrollView.
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var localUsageEmptyState: some View {
        switch localUsageStatus {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("usage.loading_ccusage"))
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .empty, .available:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("usage.no_local_today_title"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                    Text(L10n.text("usage.no_local_today_message"))
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(DashboardTheme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DashboardTheme.warning)
                VStack(alignment: .leading, spacing: 5) {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("action.refresh")) {
                        onRetry()
                    }
                    .buttonStyle(.link)
                    .disabled(isRefreshing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// OpenUsage 式消费瓦片(今日/昨日/近 30 天)+ 迷你用量趋势条。
    @ViewBuilder
    private var spendTilesSection: some View {
        let tiles = insights.spendTiles()
        let trend = insights.dailyTokenTrend
        if !tiles.isEmpty || trend.count >= 2 {
            Divider().overlay(DashboardTheme.border)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tiles) { tile in
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.text(tile.labelKey))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DashboardTheme.secondaryText)
                        Spacer(minLength: 8)
                        Text("\(tile.cost.map(UsageFormatting.compactUSD) ?? L10n.text("usage.price_unavailable")) · \(UsageFormatting.compactNumber(tile.tokens)) tokens")
                            .numericFont(11)
                            .foregroundStyle(DashboardTheme.text)
                    }
                    .frame(height: 17)
                    .accessibilityElement(children: .combine)
                }

                if trend.count >= 2 {
                    HStack(alignment: .bottom, spacing: 8) {
                        Text(L10n.text("usage.trend"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DashboardTheme.secondaryText)
                        Spacer(minLength: 8)
                        MiniBarChart(values: trend)
                            .frame(maxWidth: 170)
                            .frame(height: 22)
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("usage.trend"))
                }
            }
        }
    }

    private var ringCenterText: String? {
        hoveredEntry.map {
            $0.hasCompletePricing ? L10n.usd($0.cost) : L10n.text("usage.price_unavailable")
        }
    }

    private var ringCenterCaption: String? {
        hoveredEntry.map { UsageFormatting.compactNumber($0.tokens) }
    }

    private func providerRow(_ entry: UsageInsights.ProviderUsage) -> some View {
        let isHovered = hoveredProviderID == entry.id
        let costText = entry.hasCompletePricing
            ? L10n.usd(entry.cost)
            : L10n.text("usage.price_unavailable")
        return HStack(spacing: 6) {
            Circle()
                .fill(UsageInsights.color(for: entry.id))
                .frame(width: 7, height: 7)

            Text(entry.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DashboardTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

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
            costText,
            UsageFormatting.compactNumber(entry.tokens),
            UsageFormatting.percent(insights.tokenShare(for: entry))
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(L10n.format(
            "usage.provider_accessibility",
            UsageFormatting.percent(insights.tokenShare(for: entry)),
            costText,
            UsageFormatting.compactNumber(entry.tokens)
        ))
    }
}
