import SwiftUI

/// Dashboard Data Sources: live status of each local source UsageDock reads,
/// any current error surfaced verbatim, and the privacy posture. All real.
struct DataSourcesSection: View {
    let insights: UsageInsights
    @ObservedObject var feedStore: AIFeedStore
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.dataSources.title,
                subtitle: DashboardSection.dataSources.subtitle
            )

            DashboardCard {
                VStack(alignment: .leading, spacing: 0) {
                    PanelHeader(title: "数据来源状态")
                        .padding(.bottom, 12)
                    SourceHealthRow(
                        name: "Claude Code",
                        detail: "本机 Claude Code 执行 /usage 后解析官方额度",
                        present: insights.claude != nil,
                        capturedAt: insights.claude?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "Codex 会话",
                        detail: "读取 ~/.codex 会话中的服务端 rate-limit 快照",
                        present: insights.codex != nil,
                        capturedAt: insights.codex?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "ccusage",
                        detail: "npx ccusage 统计本地日志中的 token 与预估成本",
                        present: insights.daily != nil,
                        capturedAt: insights.daily?.capturedAt
                    )
                    rowDivider
                    SourceHealthRow(
                        name: "AI 精选动态",
                        detail: feedSourceDetail,
                        present: feedStore.lastUpdated != nil,
                        capturedAt: feedStore.lastUpdated
                    )
                }
            }

            if let errorMessage {
                DashboardCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("最近一次刷新的诊断信息", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DashboardTheme.warning)
                        Text(errorMessage)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(title: "隐私")
                    RoadmapList(items: [
                        "所有数据留在本机，UsageDock 不做任何上传。",
                        "不读取或修改 Claude Code 的钥匙串凭证；认证由 Claude Code 自行处理。",
                        "Codex 数据来自本地会话文件的服务端快照。",
                        "ccusage 成本是 API 标价估算，不等于订阅账单。",
                        "AI 精选动态由内置策略自动同步；用户无需选择账号或管理数据源。"
                    ])
                }
            }
        }
    }

    private var rowDivider: some View {
        Divider().overlay(DashboardTheme.border).padding(.vertical, 12)
    }

    private var feedSourceDetail: String {
        feedStore.lastUpdated == nil
            ? "等待后台同步精选内容"
            : "后台自动筛选额度、产品发布与服务状态更新"
    }
}

private struct SourceHealthRow: View {
    let name: String
    let detail: String
    let present: Bool
    let capturedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(present ? DashboardTheme.success : DashboardTheme.mutedText)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(present ? "正常" : "暂无数据")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(present ? DashboardTheme.success : DashboardTheme.mutedText)
                if let capturedAt {
                    Text(capturedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(DashboardTheme.mutedText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
