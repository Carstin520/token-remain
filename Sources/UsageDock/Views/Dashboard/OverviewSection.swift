import SwiftUI

/// Dashboard Overview: risk-first KPIs and today's real ccusage composition plus
/// live official quotas. Every value is derived from `UsageInsights`; anything
/// that would require multi-day history lives in the Trends section instead.
struct OverviewSection: View {
    let insights: UsageInsights
    @ObservedObject var feedStore: AIFeedStore
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.overview.title,
                subtitle: DashboardSection.overview.subtitle,
                trailing: updatedText
            )

            kpiRow

            HStack(alignment: .top, spacing: 14) {
                UsageCostCompositionCard(insights: insights)
                officialQuotaPanel
            }

            HStack(alignment: .top, spacing: 14) {
                TrendingStoriesCard(posts: feedStore.topStories)
                riskDetailPanel
            }

            AIFeedSection(store: feedStore)
        }
    }

    private var updatedText: String? {
        insights.lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .standard))" }
    }

    // MARK: - KPIs (all real)

    private var kpiRow: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let risk = insights.riskLevel(at: context.date)

            HStack(alignment: .top, spacing: 13) {
                MetricCard(
                    label: "最低可用额度",
                    value: insights.minRemainingPercent.map { UsageFormatting.percent($0) } ?? "—",
                    caption: "\(risk.badge) RISK",
                    captionColor: risk.tint,
                    valueColor: risk == .unknown ? DashboardTheme.text : risk.tint
                )
                MetricCard(
                    label: "今日 Tokens",
                    value: insights.totalTokens.map { UsageFormatting.compactNumber($0) } ?? "—",
                    caption: "ccusage 本地统计",
                    captionColor: DashboardTheme.secondaryText
                )
                MetricCard(
                    label: "今日预估成本",
                    value: insights.totalCost.map { String(format: "$%.2f", $0) } ?? "—",
                    caption: "API 标价估算",
                    captionColor: DashboardTheme.secondaryText
                )
                sustainabilityMetric(at: context.date)
            }
        }
    }

    private func sustainabilityMetric(at now: Date) -> MetricCard {
        guard let assessment = insights.paceAssessment(at: now),
              let runOutAt = assessment.pace.estimatedRunOutAt
        else {
            return MetricCard(
                label: "额度可持续性",
                value: insights.riskLevel(at: now) == .unknown ? "—" : "可到重置",
                caption: "按当前窗口平均节奏",
                captionColor: insights.riskLevel(at: now) == .unknown
                    ? DashboardTheme.secondaryText
                    : DashboardTheme.success,
                valueColor: DashboardTheme.text
            )
        }

        let provider = assessment.window.provider == .claude ? "Claude" : "Codex"
        let window = UsageFormatting.windowName(minutes: assessment.window.windowMinutes)
        return MetricCard(
            label: "预计可用",
            value: UsageFormatting.durationUntil(runOutAt, now: now),
            caption: "\(provider) \(window) · 早于重置",
            captionColor: DashboardTheme.warning,
            valueColor: DashboardTheme.warning
        )
    }

    // MARK: - Official quota (real, live)

    private var officialQuotaPanel: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "官方额度", subtitle: "各服务商最紧张的窗口") {
                    TagPill(text: "LIVE", color: DashboardTheme.codex, background: DashboardTheme.surface2)
                }

                let providers: [ProviderQuota.Provider] = [.claude, .codex]
                let rows = providers.compactMap { scarcestWindow(for: $0) }

                if rows.isEmpty {
                    EmptyStateView(
                        icon: "gauge.with.dots.needle.bottom.0percent",
                        title: "正在读取官方额度",
                        message: "Claude 与 Codex 的服务端额度快照稍后会自动出现。"
                    )
                } else {
                    ForEach(rows) { window in
                        OfficialQuotaRow(window: window)
                    }
                    Divider().overlay(DashboardTheme.border)
                    HStack {
                        Text("风险等级")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                        Spacer()
                        PixelBadge(
                            text: insights.riskLevel.badge,
                            color: insights.riskLevel.tint,
                            filled: insights.riskLevel == .high
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func scarcestWindow(for provider: ProviderQuota.Provider) -> UsageInsights.Window? {
        insights.windows
            .filter { $0.provider == provider }
            .min { $0.remainingPercent < $1.remainingPercent }
    }

    // MARK: - Risk detail (real)

    private var riskDetailPanel: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                let now = Date()
                let risk = insights.riskLevel(at: now)
                let paceAssessment = insights.paceAssessment(at: now)

                PanelHeader(title: "风险提示", subtitle: "基于最紧张的额度窗口")

                HStack(spacing: 8) {
                    PixelBadge(text: risk.badge, color: risk.tint, filled: risk == .high)
                    Text(insights.decisionHeadline(at: now))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                }

                Text(insights.decisionSummary(at: now))
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let window = paceAssessment?.window ?? insights.constrainingWindow {
                    Divider().overlay(DashboardTheme.border)
                    InfoRow(
                        label: "最紧张窗口",
                        value: "\(window.provider == .claude ? "Claude" : "Codex") · \(UsageFormatting.windowName(minutes: window.windowMinutes))"
                    )
                    InfoRow(
                        label: "剩余额度",
                        value: UsageFormatting.percent(window.remainingPercent),
                        valueColor: risk.tint
                    )
                    if let runOutAt = paceAssessment?.pace.estimatedRunOutAt {
                        InfoRow(
                            label: "预计用尽",
                            value: UsageFormatting.durationUntil(runOutAt, now: now) + "后",
                            valueColor: DashboardTheme.warning
                        )
                    }
                    if let reset = window.resetsAt {
                        InfoRow(label: "预计重置", value: UsageFormatting.resetDescription(to: reset))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A provider's scarcest window shown as a mini progress summary.
private struct OfficialQuotaRow: View {
    let window: UsageInsights.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                BrandIcon(provider: window.provider)
                    .frame(width: 18, height: 18)
                Text(window.provider == .claude ? "Claude" : "Codex")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Spacer()
                Text(UsageFormatting.percent(window.remainingPercent))
                    .numericFont(13, .bold)
                    .foregroundStyle(DashboardTheme.text)
            }
            SegmentBar(value: window.remainingPercent / 100, accent: DashboardTheme.accent(for: window.provider), height: 5)
            HStack {
                Text(UsageFormatting.windowName(minutes: window.windowMinutes) + "窗口")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.mutedText)
                Spacer()
                if let reset = window.resetsAt {
                    Text(UsageFormatting.resetDescription(to: reset))
                        .numericFont(10)
                        .foregroundStyle(DashboardTheme.mutedText)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.provider == .claude ? "Claude" : "Codex") 剩余 \(UsageFormatting.percent(window.remainingPercent))")
    }
}
