import SwiftUI

/// Dashboard Trends: a real stacked daily bar chart backed by ccusage's
/// `daily --by-agent` history. When fewer than two days of history exist we keep
/// an honest "accumulating by day" empty state rather than fabricate a curve.
struct TrendsSection: View {
    let insights: UsageInsights

    /// Real per-day history, oldest-first; nil / <2 days ⇒ honest empty state.
    private var trendDays: [DailyUsageHistory.Day]? {
        guard let days = insights.history?.days, days.count >= 2 else { return nil }
        return days
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.trends.title,
                subtitle: DashboardSection.trends.subtitle
            )

            if let trendDays {
                UsageTrendCard(days: trendDays, capturedAt: insights.history?.capturedAt)
            } else {
                DashboardCard {
                    EmptyStateView(
                        icon: "chart.bar.xaxis",
                        title: L10n.text("trends.accumulating_title"),
                        message: L10n.text("trends.accumulating_message")
                    )
                }
            }

            HStack(alignment: .top, spacing: 14) {
                currentSnapshotPanel
                roadmapPanel
            }
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
                    Divider().overlay(DashboardTheme.border)
                    ForEach(insights.providerUsage) { usage in
                        InfoRow(
                            label: usage.displayName,
                            value: "\(UsageFormatting.compactNumber(usage.tokens)) · \(String(format: "$%.2f", usage.cost))"
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
