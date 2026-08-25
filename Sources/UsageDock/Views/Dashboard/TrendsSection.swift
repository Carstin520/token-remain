import SwiftUI

/// Dashboard Trends: a real stacked daily bar chart backed by ccusage's
/// `daily --by-agent` history. When fewer than two days of history exist we keep
/// an honest "accumulating by day" empty state rather than fabricate a curve.
struct TrendsSection: View {
    let insights: UsageInsights
    let localUsageStatus: UsageStore.LocalUsageStatus
    let isCCUsageRefreshing: Bool
    let onRetryCCUsage: () -> Void
    @ObservedObject var tracked: TrackedProvidersStore
    let disabledLocalUsageSourceIDs: Set<String>

    /// Real per-day history, oldest-first; nil / <2 days ⇒ honest empty state.
    private var trendDays: [DailyUsageHistory.Day]? {
        guard let days = insights.history?.days, days.count >= 2 else { return nil }
        return days
    }

    private var preferredAgentIDs: Set<String> {
        Set(tracked.enabledOrdered.map(\.ccusageAgentID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.trends.title,
                subtitle: DashboardSection.trends.subtitle
            )

            if let trendDays {
                UsageTrendCard(
                    days: trendDays,
                    capturedAt: insights.history?.capturedAt,
                    preferredAgentIDs: preferredAgentIDs,
                    excludedAgentIDs: disabledLocalUsageSourceIDs
                )
                if !insights.historyUnpricedModels.isEmpty {
                    Label(
                        L10n.format(
                            "trends.unpriced_history_format",
                            insights.historyUnpricedModels.joined(separator: L10n.text("common.list_separator"))
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DashboardTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                DashboardCard {
                    historyEmptyState
                }
            }

            QuotaConsumptionTrendCard(
                history: insights.quotaUsageHistory,
                enabledProviders: tracked.enabledOrdered
            )

            HStack(alignment: .top, spacing: 14) {
                currentSnapshotPanel
                roadmapPanel
            }
        }
    }

    @ViewBuilder
    private var historyEmptyState: some View {
        switch localUsageStatus {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.text("usage.loading_ccusage"))
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 110)

        case .failed(let message):
            VStack(spacing: 10) {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: L10n.text("datasource.broken"),
                    message: message
                )
                Button(L10n.text("action.refresh")) {
                    onRetryCCUsage()
                }
                .buttonStyle(.bordered)
                .disabled(isCCUsageRefreshing)
            }

        case .available, .empty:
            EmptyStateView(
                icon: "chart.bar.xaxis",
                title: L10n.text("trends.accumulating_title"),
                message: L10n.text("trends.accumulating_message")
            )
        }
    }

    private var currentSnapshotPanel: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(title: L10n.text("trends.snapshot_title"), subtitle: L10n.text("trends.snapshot_subtitle"))

                if insights.totalTokens == nil {
                    Text(L10n.text("trends.no_local_usage_today"))
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                } else {
                    InfoRow(label: L10n.text("usage.today_tokens"), value: insights.totalTokens.map { UsageFormatting.compactNumber($0) } ?? "—")
                    InfoRow(label: L10n.text("usage.today_est_cost"), value: insights.totalCost.map { String(format: "$%.2f", $0) } ?? "—")
                    Divider().overlay(DashboardSurface.border)
                    ForEach(insights.providerUsage) { usage in
                        InfoRow(
                            label: usage.displayName,
                            value: "\(UsageFormatting.compactNumber(usage.tokens)) · \(usage.hasCompletePricing ? String(format: "$%.2f", usage.cost) : L10n.text("usage.price_unavailable"))"
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var roadmapPanel: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: L10n.text("trends.roadmap_title"), subtitle: L10n.text("trends.roadmap_subtitle"))
                RoadmapList(items: [
                    L10n.text("trends.roadmap.heatmap"),
                    L10n.text("trends.roadmap.cost_share_history"),
                    L10n.text("trends.roadmap.limit_alerts")
                ])
            }
        }
        .frame(maxWidth: .infinity)
    }
}
