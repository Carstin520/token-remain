import SwiftUI

/// Dashboard Overview: the screen answers "will any quota run out before it
/// resets?" first. The title row states the finding once (window, pace gap,
/// run-out time, reset), the KPI strip leads with the window that runs out
/// first, and the window table lists every official window by urgency.
/// Every value is derived from `UsageInsights`; anything that would require
/// multi-day history lives in the Trends section instead.
struct OverviewSection: View {
    let insights: UsageInsights
    let notices: [ProviderQuota.Provider: String]
    let subscriptionAccounts: [SubscriptionAccountInput]
    let localUsageStatus: UsageStore.LocalUsageStatus
    let isCCUsageRefreshing: Bool
    let onRetryCCUsage: () -> Void
    @ObservedObject var feedStore: AIFeedStore
    @ObservedObject var preferences: PreferencesStore = .shared
    @ObservedObject private var currencyStore = CurrencyStore.shared
    /// Observed so a plan chosen on the subscription card also changes the
    /// window table's badge.
    @ObservedObject private var costStore = SubscriptionCostStore.shared
    let errorMessage: String?

    var body: some View {
        // One gutter for every gap on the screen, vertical and horizontal.
        VStack(alignment: .leading, spacing: DashboardOverviewLayout.gridSpacing) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: DashboardOverviewLayout.gridSpacing) {
                    titleRow(at: context.date)

                    OverviewKPIStrip(
                        insights: insights,
                        now: context.date,
                        tokens: tokensCell,
                        cost: costCell
                    )

                    mainRow(now: context.date, windows: QuotaWindowsPanel(
                        groups: QuotaWindowTable.groups(
                            quotas: insights.quotas,
                            notices: notices,
                            plans: planLabels,
                            refreshInterval: preferences.refreshInterval,
                            now: context.date
                        ),
                        now: context.date
                    ))
                }
            }

            SubscriptionCostCard(
                accounts: subscriptionAccounts,
                history: insights.quotaUsageHistory,
                tokenHistory: insights.history
            )
        }
        .pageReveal()
    }

    /// The window table spans the canvas and is exactly as tall as the
    /// tracked apps need, so one or two apps make a short band instead of a
    /// half-empty column. Today's usage and the trending stories share the
    /// row below at one height; narrower than `cardRowWidth` they stack.
    private static let cardRowWidth: CGFloat = 640

    private func mainRow(now: Date, windows: QuotaWindowsPanel) -> some View {
        let usage = UsageCostCompositionCard(
            insights: insights,
            localUsageStatus: localUsageStatus,
            isRefreshing: isCCUsageRefreshing,
            onRetry: onRetryCCUsage
        )
        let trending = TrendingStoriesCard(posts: feedStore.topStories, now: now)
        return VStack(spacing: DashboardOverviewLayout.gridSpacing) {
            windows
            // Side by side at the taller card's height, so the row ends on
            // one line whatever today's usage or the feed holds; stacked when
            // narrower. One copy of each card either way.
            AdaptiveRowLayout(minimumWidth: Self.cardRowWidth, spacing: DashboardOverviewLayout.gridSpacing) {
                usage
                trending
            }
            .environment(\.overviewPanelFillsHeight, true)
        }
    }

    /// The same summary the subscription card draws; prices play no part.
    private var planLabels: [ProviderQuota.Provider: String] {
        QuotaWindowTable.planLabels(from: SubscriptionCostSummary.make(
            accounts: subscriptionAccounts,
            overrides: costStore.overrides,
            rates: nil
        ))
    }

    private var updatedText: String? {
        insights.lastUpdated.map { L10n.format("common.updated_at", $0.formatted(date: .omitted, time: .standard)) }
    }

    // MARK: - Title row

    /// With a projected run-out the subtitle becomes the finding, led by the
    /// risk badge — the only place the risk level appears on this screen.
    /// Without one the page keeps its descriptive subtitle.
    @ViewBuilder
    private func titleRow(at now: Date) -> some View {
        if let finding = finding(at: now) {
            let risk = insights.riskLevel(at: now)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(DashboardSection.overview.title)
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(DashboardTheme.text)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PixelBadge(text: risk.badge, color: risk.tint, filled: risk == .high)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(finding)
                            .numericFont(12)
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if let updatedText {
                    Text(updatedText)
                        .numericFont(12)
                        .foregroundStyle(DashboardTheme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else {
            SectionTitleHeader(
                title: DashboardSection.overview.title,
                subtitle: DashboardSection.overview.subtitle,
                trailing: updatedText
            )
        }
    }

    private func finding(at now: Date) -> String? {
        guard let assessment = insights.paceAssessment(at: now),
              let runOutAt = assessment.pace.estimatedRunOutAt
        else { return nil }
        let window = assessment.window
        // A used-up window reports `now` as its run-out time; say so plainly
        // instead of projecting "runs out in less than a minute".
        if assessment.pace.isExhausted {
            var parts = [
                "\(window.displayName) \(UsageFormatting.windowName(minutes: window.windowMinutes))",
                L10n.text("pace.exhausted"),
            ]
            if let reset = window.resetsAt {
                parts.append(UsageFormatting.resetDescription(to: reset, now: now))
            }
            return parts.joined(separator: " · ")
        }
        guard let reset = window.resetsAt else { return insights.decisionSummary(at: now) }
        return L10n.format(
            "overview.finding.projected",
            window.displayName,
            UsageFormatting.windowName(minutes: window.windowMinutes),
            UsageFormatting.percent(abs(assessment.pace.deltaPercent)),
            UsageFormatting.durationUntil(runOutAt, now: now),
            UsageFormatting.resetDescription(to: reset, now: now)
        )
    }

    // MARK: - KPI cells (all real)

    private var tokensCell: OverviewKPIStrip.Cell {
        OverviewKPIStrip.Cell(
            label: L10n.text("usage.today_tokens"),
            value: insights.totalTokens.map { UsageFormatting.compactNumber($0) } ?? "—",
            caption: L10n.text("usage.ccusage_local")
        )
    }

    private var costCell: OverviewKPIStrip.Cell {
        OverviewKPIStrip.Cell(
            label: L10n.text("usage.today_est_cost"),
            value: insights.totalCost.map { currencyStore.display.amount(usd: $0) } ?? "—",
            caption: insights.unpricedModels.isEmpty
                ? L10n.text("usage.api_price_estimate")
                : L10n.text("usage.price_unavailable"),
            captionColor: insights.unpricedModels.isEmpty
                ? DashboardTheme.secondaryText
                : DashboardTheme.warning
        )
    }
}
