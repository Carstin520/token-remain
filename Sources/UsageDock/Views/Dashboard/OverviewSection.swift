import SwiftUI

/// Dashboard Overview: risk-first KPIs and today's real ccusage composition plus
/// live official quotas. Every value is derived from `UsageInsights`; anything
/// that would require multi-day history lives in the Trends section instead.
struct OverviewSection: View {
    let insights: UsageInsights
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
                todayCompositionPanel
                officialQuotaPanel
            }

            HStack(alignment: .top, spacing: 14) {
                costSplitPanel
                riskDetailPanel
            }
        }
    }

    private var updatedText: String? {
        insights.lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .standard))" }
    }

    // MARK: - KPIs (all real)

    private var kpiRow: some View {
        HStack(alignment: .top, spacing: 13) {
            MetricCard(
                label: "最低可用额度",
                value: insights.minRemainingPercent.map { UsageFormatting.percent($0) } ?? "—",
                caption: "\(insights.riskLevel.badge) RISK",
                captionColor: insights.riskLevel.tint,
                valueColor: insights.riskLevel == .unknown ? DashboardTheme.text : insights.riskLevel.tint
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
            MetricCard(
                label: "活跃数据源",
                value: "\(activeSourceCount)/3",
                caption: errorMessage == nil ? "全部数据源正常" : "部分数据源异常",
                captionColor: errorMessage == nil ? DashboardTheme.success : DashboardTheme.warning
            )
        }
    }

    private var activeSourceCount: Int {
        [insights.claude != nil, insights.codex != nil, insights.daily != nil].filter { $0 }.count
    }

    // MARK: - Today composition (real)

    private var todayCompositionPanel: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "今日用量构成", subtitle: "按服务商统计 · 本地 ccusage")

                if insights.providerUsage.isEmpty {
                    EmptyStateView(
                        icon: "chart.bar.xaxis",
                        title: "今日暂无本地用量",
                        message: "运行一次 Claude Code 或 Codex 后，ccusage 会记录今日 token 与预估成本。"
                    )
                } else {
                    ForEach(insights.providerUsage) { usage in
                        CompositionBar(usage: usage, total: insights.totalTokens ?? 0)
                    }
                    Text("以上为今日快照；跨天趋势见 Trends。")
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.mutedText)
                }
            }
        }
        .frame(maxWidth: .infinity)
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
                        Text(insights.riskLevel.badge)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(insights.riskLevel.tint)
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

    // MARK: - Cost split (real, today)

    private var costSplitPanel: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "今日成本构成", subtitle: "按服务商拆分 · 本地 ccusage")

                let entries = insights.providerUsage.filter { $0.cost > 0 }
                if entries.isEmpty {
                    EmptyStateView(
                        icon: "chart.pie",
                        title: "今日暂无成本数据",
                        message: "有本地用量后，这里会显示今日预估成本在服务商之间的占比。"
                    )
                } else {
                    HStack(alignment: .center, spacing: 20) {
                        RingChart(
                            segments: entries.map {
                                RingChart.Segment(id: $0.id, value: $0.cost, color: UsageInsights.color(for: $0.id))
                            },
                            centerText: String(format: "$%.2f", insights.totalCost ?? 0)
                        )
                        .frame(width: 112, height: 112)

                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(entries) { entry in
                                HStack {
                                    Circle().fill(UsageInsights.color(for: entry.id)).frame(width: 7, height: 7)
                                    Text(entry.displayName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(DashboardTheme.secondaryText)
                                    Spacer()
                                    Text(costShare(entry.cost))
                                        .font(.system(size: 11, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(DashboardTheme.text)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func costShare(_ cost: Double) -> String {
        guard let total = insights.totalCost, total > 0 else { return "—" }
        return UsageFormatting.percent(cost / total * 100)
    }

    // MARK: - Risk detail (real)

    private var riskDetailPanel: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(title: "风险提示", subtitle: "基于最紧张的额度窗口")

                HStack(spacing: 8) {
                    TagPill(text: insights.riskLevel.badge, color: insights.riskLevel.tint, background: DashboardTheme.surface2)
                    Text(insights.riskLevel.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                }

                Text(insights.riskLevel.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let window = insights.constrainingWindow {
                    Divider().overlay(DashboardTheme.border)
                    InfoRow(
                        label: "最紧张窗口",
                        value: "\(window.provider == .claude ? "Claude" : "Codex") · \(UsageFormatting.windowName(minutes: window.windowMinutes))"
                    )
                    InfoRow(
                        label: "剩余额度",
                        value: UsageFormatting.percent(window.remainingPercent),
                        valueColor: insights.riskLevel.tint
                    )
                    if let reset = window.resetsAt {
                        InfoRow(label: "预计重置", value: UsageFormatting.resetDescription(to: reset))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One provider's share of today's tokens, as a labeled bar.
private struct CompositionBar: View {
    let usage: UsageInsights.ProviderUsage
    let total: Int64

    private var fraction: Double {
        total > 0 ? Double(usage.tokens) / Double(total) : 0
    }

    private var fill: LinearGradient {
        switch usage.provider {
        case .claude: return DashboardTheme.claudeFill
        case .codex: return DashboardTheme.codexFill
        case .none:
            return LinearGradient(colors: [DashboardTheme.purple, DashboardTheme.purple.opacity(0.7)], startPoint: .leading, endPoint: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DashboardTheme.text)
                Spacer()
                Text("\(UsageFormatting.compactNumber(usage.tokens)) · \(String(format: "$%.2f", usage.cost))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            UsageProgressBar(value: fraction, fill: fill, height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A provider's scarcest window shown as a mini progress summary.
private struct OfficialQuotaRow: View {
    let window: UsageInsights.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                BrandIcon(provider: window.provider)
                    .foregroundStyle(DashboardTheme.text)
                    .frame(width: 18, height: 18)
                Text(window.provider == .claude ? "Claude" : "Codex")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Spacer()
                Text(UsageFormatting.percent(window.remainingPercent))
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DashboardTheme.text)
            }
            UsageProgressBar(value: window.remainingPercent / 100, fill: DashboardTheme.fill(for: window.provider), height: 5)
            HStack {
                Text(UsageFormatting.windowName(minutes: window.windowMinutes) + "窗口")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.mutedText)
                Spacer()
                if let reset = window.resetsAt {
                    Text(UsageFormatting.resetDescription(to: reset))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(DashboardTheme.mutedText)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.provider == .claude ? "Claude" : "Codex") 剩余 \(UsageFormatting.percent(window.remainingPercent))")
    }
}
