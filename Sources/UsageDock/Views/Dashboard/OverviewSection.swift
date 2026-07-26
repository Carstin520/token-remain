import SwiftUI

/// Dashboard Overview: risk-first KPIs and today's real ccusage composition plus
/// live official quotas. Every value is derived from `UsageInsights`; anything
/// that would require multi-day history lives in the Trends section instead.
struct OverviewSection: View {
    let insights: UsageInsights
    let localUsageStatus: UsageStore.LocalUsageStatus
    let isCCUsageRefreshing: Bool
    let onRetryCCUsage: () -> Void
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
                UsageCostCompositionCard(
                    insights: insights,
                    localUsageStatus: localUsageStatus,
                    isRefreshing: isCCUsageRefreshing,
                    onRetry: onRetryCCUsage
                )
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
        insights.lastUpdated.map { L10n.format("common.updated_at", $0.formatted(date: .omitted, time: .standard)) }
    }

    // MARK: - KPIs (all real)

    private var kpiRow: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let risk = insights.riskLevel(at: context.date)

            HStack(alignment: .top, spacing: 13) {
                MetricCard(
                    label: L10n.text("overview.kpi.min_remaining"),
                    value: insights.minRemainingPercent.map { UsageFormatting.percent($0) } ?? "—",
                    caption: "\(risk.badge) RISK",
                    captionColor: risk.tint,
                    valueColor: risk == .unknown ? DashboardTheme.text : risk.tint
                )
                MetricCard(
                    label: L10n.text("usage.today_tokens"),
                    value: insights.totalTokens.map { UsageFormatting.compactNumber($0) } ?? "—",
                    caption: L10n.text("usage.ccusage_local"),
                    captionColor: DashboardTheme.secondaryText
                )
                MetricCard(
                    label: L10n.text("usage.today_est_cost"),
                    value: insights.totalCost.map { String(format: "$%.2f", $0) } ?? "—",
                    caption: insights.unpricedModels.isEmpty
                        ? L10n.text("usage.api_price_estimate")
                        : L10n.text("usage.price_unavailable"),
                    captionColor: insights.unpricedModels.isEmpty
                        ? DashboardTheme.secondaryText
                        : DashboardTheme.warning
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
                label: L10n.text("overview.kpi.sustainability"),
                value: insights.riskLevel(at: now) == .unknown ? "—" : L10n.text("overview.kpi.until_reset"),
                caption: L10n.text("overview.kpi.pace_basis"),
                captionColor: insights.riskLevel(at: now) == .unknown
                    ? DashboardTheme.secondaryText
                    : DashboardTheme.success,
                valueColor: DashboardTheme.text
            )
        }

        let provider = assessment.window.provider.displayName
        let window = UsageFormatting.windowName(minutes: assessment.window.windowMinutes)
        return MetricCard(
            label: L10n.text("overview.kpi.projected_available"),
            value: UsageFormatting.durationUntil(runOutAt, now: now),
            caption: L10n.format("overview.kpi.window_before_reset", provider, window),
            captionColor: DashboardTheme.warning,
            valueColor: DashboardTheme.warning
        )
    }

    // MARK: - Official quota (real, live)

    private var officialQuotaPanel: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: L10n.text("quota.official_title"), subtitle: L10n.text("quota.official_subtitle")) {
                    TagPill(text: "LIVE", color: DashboardTheme.codex, background: DashboardTheme.surface2)
                }

                let rows = officialQuotaProviders.compactMap { scarcestWindow(for: $0) }

                if rows.isEmpty {
                    EmptyStateView(
                        icon: "gauge.with.dots.needle.bottom.0percent",
                        title: L10n.text("quota.loading_official_title"),
                        message: L10n.text("quota.loading_official_message")
                    )
                } else {
                    ForEach(rows) { window in
                        OfficialQuotaRow(window: window)
                    }
                    Divider().overlay(DashboardTheme.border)
                    HStack {
                        Text(L10n.text("overview.risk_level"))
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

    /// 今日 token 用量最高的两个 provider;没有本地统计时默认 Claude / Codex。
    /// 排名靠前但没有官方额度快照的候选会被顺延,保证只要有数据就凑满两行。
    private var officialQuotaProviders: [ProviderQuota.Provider] {
        var candidates = insights.providersByTokenUsage
        let fallbacks = [ProviderQuota.Provider.claude, .codex] + insights.quotas.map(\.provider)
        for fallback in fallbacks where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return Array(candidates.filter { scarcestWindow(for: $0) != nil }.prefix(2))
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

                PanelHeader(title: L10n.text("overview.risk_panel_title"), subtitle: L10n.text("overview.risk_panel_subtitle"))

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
                        label: L10n.text("overview.scarcest_window"),
                        value: "\(window.provider.displayName) · \(UsageFormatting.windowName(minutes: window.windowMinutes))"
                    )
                    InfoRow(
                        label: L10n.text("overview.remaining_quota"),
                        value: UsageFormatting.percent(window.remainingPercent),
                        valueColor: risk.tint
                    )
                    if let runOutAt = paceAssessment?.pace.estimatedRunOutAt {
                        InfoRow(
                            label: L10n.text("overview.projected_depletion"),
                            value: L10n.format("overview.in_duration", UsageFormatting.durationUntil(runOutAt, now: now)),
                            valueColor: DashboardTheme.warning
                        )
                    }
                    if let reset = window.resetsAt {
                        InfoRow(label: L10n.text("overview.projected_reset"), value: UsageFormatting.resetDescription(to: reset))
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
                Text(window.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)
                Spacer()
                Text(UsageFormatting.percent(window.remainingPercent))
                    .numericFont(13, .bold)
                    .foregroundStyle(DashboardTheme.text)
            }
            SegmentBar(
                value: window.remainingPercent / 100,
                accent: DashboardTheme.quotaAccent(
                    for: window.provider,
                    remainingPercent: window.remainingPercent
                ),
                height: 5
            )
            HStack {
                Text(L10n.format("quota.window", UsageFormatting.windowName(minutes: window.windowMinutes)))
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
        .accessibilityLabel(L10n.format("quota.provider_remaining", window.provider.displayName, UsageFormatting.percent(window.remainingPercent)))
    }
}
