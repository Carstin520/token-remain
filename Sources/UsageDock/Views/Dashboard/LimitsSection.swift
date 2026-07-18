import SwiftUI

/// Dashboard Limits: the authoritative view of every official quota window for
/// Claude and Codex, reusing the popover's `QuotaCard`. Pure live data.
struct LimitsSection: View {
    let insights: UsageInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.limits.title,
                subtitle: DashboardSection.limits.subtitle,
                trailing: insights.lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .standard))" }
            )

            HStack(alignment: .top, spacing: 14) {
                QuotaCard(provider: .claude, quota: insights.claude)
                    .frame(maxWidth: .infinity)
                QuotaCard(provider: .codex, quota: insights.codex)
                    .frame(maxWidth: .infinity)
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(title: "关于额度窗口")
                    Text("所有百分比表示窗口内的剩余额度。窗口由各服务端直接提供：Claude 通常包含 5 小时会话窗口与 7 天窗口；Codex 依服务端返回展示，当前可能仅提供 7 天窗口。")
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("重置时间来自官方快照；若某窗口暂未提供重置时间，会显示“待官方提供”。")
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
