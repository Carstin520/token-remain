import SwiftUI

/// Today's local ccusage snapshot as one dense card: a cost-share donut on the
/// left, one row per provider on the right.
///
/// The ring encodes estimated **cost** share only — mixing tokens and currency
/// in a single ring would make the arcs unreadable. Token totals stay as
/// explicit labels beside each provider instead.
struct UsageCostCompositionCard: View {
    let insights: UsageInsights
    let localUsageStatus: UsageStore.LocalUsageStatus
    let isRefreshing: Bool
    let onRetry: () -> Void

    private var entries: [UsageInsights.ProviderUsage] {
        insights.providerUsage
    }

    /// Only providers with a positive cost can be drawn as ring arcs; a
    /// zero-cost provider still deserves a row, just no wedge.
    private var costedEntries: [UsageInsights.ProviderUsage] {
        guard insights.totalCost != nil else { return [] }
        return entries.filter { $0.cost > 0 }
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: L10n.text("usage.today_cost_title"), subtitle: L10n.text("usage.today_cost_subtitle"))

                if entries.isEmpty {
                    emptyState
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        ring
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(entries) { entry in
                                ProviderUsageRow(
                                    usage: entry,
                                    share: insights.totalCost == nil
                                        ? nil
                                        : insights.costShare(for: entry)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !insights.unpricedModels.isEmpty {
                        Label(
                            L10n.format(
                                "usage.unpriced_models_format",
                                insights.unpricedModels.joined(separator: L10n.text("common.list_separator"))
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DashboardTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(L10n.text("usage.snapshot_note"))
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.mutedText)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch localUsageStatus {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.text("usage.loading_ccusage"))
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 108)

        case .empty, .available:
            EmptyStateView(
                icon: "chart.pie",
                title: L10n.text("usage.no_local_today_title"),
                message: L10n.text("usage.no_local_today_message")
            )

        case .failed(let message):
            VStack(spacing: 10) {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: L10n.text("datasource.broken"),
                    message: message
                )
                Button(L10n.text("action.refresh")) {
                    onRetry()
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
            }
        }
    }

    private var ring: some View {
        RingChart(
            segments: costedEntries.map {
                RingChart.Segment(id: $0.id, value: $0.cost, color: UsageInsights.color(for: $0.id))
            },
            lineWidth: 16,
            centerText: insights.totalCost.map { String(format: "$%.2f", $0) } ?? "—",
            centerCaption: insights.unpricedModels.isEmpty
                ? L10n.text("usage.today_estimate")
                : L10n.text("usage.price_unavailable"),
            centerTextSize: 17
        )
        .frame(width: 108, height: 108)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("usage.today_est_cost_accessibility", insights.totalCost.map { L10n.format("usage.usd_amount", $0) } ?? L10n.text("common.no_data")))
    }
}

/// One provider line: dot, name, compact tokens, cost, and a bold cost share.
///
/// The share is the emphasized value because it is what the donut encodes;
/// tokens and dollars read as supporting detail.
private struct ProviderUsageRow: View {
    let usage: UsageInsights.ProviderUsage
    let share: Double?

    var body: some View {
        let costText = usage.hasCompletePricing
            ? String(format: "$%.2f", usage.cost)
            : L10n.text("usage.price_unavailable")
        HStack(spacing: 8) {
            Circle()
                .fill(UsageInsights.color(for: usage.id))
                .frame(width: 7, height: 7)

            Text(usage.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DashboardTheme.text)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text("\(UsageFormatting.compactNumber(usage.tokens)) · \(costText)")
                .numericFont(10)
                .foregroundStyle(DashboardTheme.secondaryText)
                .lineLimit(1)

            Text(share.map(UsageFormatting.percent) ?? "—")
                .numericFont(12, .bold)
                .foregroundStyle(DashboardTheme.text)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(usage.hasCompletePricing && share != nil
            ? L10n.format(
                "usage.provider_cost_accessibility",
                usage.displayName,
                UsageFormatting.compactNumber(usage.tokens),
                usage.cost,
                UsageFormatting.percent(share ?? 0)
            )
            : L10n.format(
                "usage.provider_price_unavailable_accessibility",
                usage.displayName,
                UsageFormatting.compactNumber(usage.tokens)
            ))
    }
}
