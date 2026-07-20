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
                        title: "趋势数据按日累积中",
                        message: "每日用量趋势需要至少两天的本地历史。你每天使用 Claude Code / Codex 后,ccusage 会按日累积 token 与成本,凑齐后这里会自动显示真实的堆叠柱状趋势,绝不虚构曲线。"
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
                PanelHeader(title: "今日快照", subtitle: "趋势累积的起点 · 本地 ccusage")

                if insights.totalTokens == nil {
                    Text("暂无今日本地用量。")
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                } else {
                    InfoRow(label: "今日 Tokens", value: insights.totalTokens.map { UsageFormatting.compactNumber($0) } ?? "—")
                    InfoRow(label: "今日预估成本", value: insights.totalCost.map { String(format: "$%.2f", $0) } ?? "—")
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
                PanelHeader(title: "规划中", subtitle: "趋势相关的产品方向")
                RoadmapList(items: [
                    "按周使用热力图",
                    "服务商成本占比的历史变化",
                    "接近额度上限时的用量提醒"
                ])
            }
        }
        .frame(maxWidth: .infinity)
    }
}
