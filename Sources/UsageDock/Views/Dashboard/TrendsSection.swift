import SwiftUI

/// Dashboard Trends: UsageDock only persists the latest snapshot today, so this
/// deliberately shows an honest empty state plus the single real data point we
/// can prove (today's snapshot) — never a fabricated multi-day curve.
struct TrendsSection: View {
    let insights: UsageInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.trends.title,
                subtitle: DashboardSection.trends.subtitle
            )

            DashboardCard {
                EmptyStateView(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "历史趋势正在积累中",
                    message: "UsageDock 目前只保存最新的用量快照，尚未按天累积 token 历史，因此这里不会展示虚构的多日曲线。持续运行后，本地快照会逐步积累成真实趋势。"
                )
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
                    "本地按天累积用量快照",
                    "最近 30 天 Token 使用趋势曲线",
                    "按周使用热力图",
                    "服务商成本占比的历史变化",
                    "接近额度上限时的用量提醒"
                ])
            }
        }
        .frame(maxWidth: .infinity)
    }
}
