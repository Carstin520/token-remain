import SwiftUI

/// Full provider quota card: brand row + plan pill, then one row per official
/// window (remaining %, progress bar, reset label). Shown in the popover and in
/// the Dashboard's Limits section. Renders a waiting state before data arrives.
struct QuotaCard: View {
    let provider: ProviderQuota.Provider
    let quota: ProviderQuota?

    var body: some View {
        DashboardCard(padding: 13) {
            VStack(alignment: .leading, spacing: 11) {
                header

                if let quota {
                    QuotaWindowRow(window: quota.primary, provider: provider)
                    if let secondary = quota.secondary {
                        Divider().overlay(DashboardTheme.border)
                        QuotaWindowRow(window: secondary, provider: provider)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let isStale = context.date.timeIntervalSince(quota.capturedAt) >= 600
                        Label {
                            Text(UsageFormatting.freshnessDescription(since: quota.capturedAt, now: context.date))
                                .numericFont(10)
                        } icon: {
                            Image(systemName: isStale ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(isStale ? DashboardTheme.warning : DashboardTheme.mutedText)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取官方额度…")
                            .font(.system(size: 12))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandIcon(provider: provider)
                .foregroundStyle(DashboardTheme.text)
                .frame(width: 20, height: 20)
            Text(provider == .claude ? "Claude" : "Codex")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DashboardTheme.text)
            Spacer()
            if let plan = quota?.planName, !plan.isEmpty {
                TagPill(text: plan)
            }
        }
    }
}

/// A single quota window inside a `QuotaCard`.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    let provider: ProviderQuota.Provider
    var showsDetails = true

    private var remainingPercent: Double {
        min(100, max(0, 100 - window.usedPercent))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: showsDetails ? 7 : 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.format("quota.window", UsageFormatting.windowName(minutes: window.windowMinutes)))
                        .font(.system(size: 13))
                        .foregroundStyle(DashboardTheme.secondaryText)
                    Spacer()
                    if let pace = UsagePace(window: window, now: context.date),
                       pace.showsRemainingWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DashboardTheme.danger)
                            .help("当前用量节奏超前")
                            .accessibilityLabel("当前用量节奏超前")
                    }
                    Text(L10n.format("quota.remaining", UsageFormatting.percent(remainingPercent)))
                        .numericFont(14, .bold)
                        .foregroundStyle(DashboardTheme.text)
                }

                SegmentBar(value: remainingPercent / 100, accent: DashboardTheme.accent(for: provider))

                if showsDetails {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                        if let resetsAt = window.resetsAt {
                            Text(UsageFormatting.resetDescription(to: resetsAt, now: context.date))
                                .numericFont(10)
                        } else {
                            Text("下次重置时间待官方提供")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                    if let pace = UsagePace(window: window, now: context.date) {
                        QuotaPaceRow(pace: pace, now: context.date)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: showsDetails)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.format(
                "quota.window_accessibility",
                provider == .claude ? "Claude" : "Codex",
                UsageFormatting.windowName(minutes: window.windowMinutes)
            )
        )
        .accessibilityValue(L10n.format("quota.remaining", UsageFormatting.percent(remainingPercent)))
    }
}

private struct QuotaPaceRow: View {
    let pace: UsagePace
    let now: Date

    private var tint: Color {
        switch pace.status {
        case .onTrack: return DashboardTheme.secondaryText
        case .reserve: return DashboardTheme.success
        case .deficit: return pace.willLastUntilReset ? DashboardTheme.warning : DashboardTheme.danger
        }
    }

    private var paceLabel: String {
        let delta = UsageFormatting.percent(abs(pace.deltaPercent))
        switch pace.status {
        case .onTrack: return L10n.text("pace.on_track")
        case .reserve: return L10n.format("pace.reserve", delta)
        case .deficit: return L10n.format("pace.deficit", delta)
        }
    }

    private var outcomeLabel: String {
        if pace.willLastUntilReset {
            return L10n.text("pace.lasts_until_reset")
        }
        guard let runOutAt = pace.estimatedRunOutAt else { return L10n.text("pace.projected_early") }
        return L10n.format("pace.projected_in", UsageFormatting.durationUntil(runOutAt, now: now))
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: pace.willLastUntilReset ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(paceLabel)
                .numericFont(10, .medium)
            Spacer(minLength: 8)
            Text(outcomeLabel)
                .numericFont(10)
        }
        .font(.system(size: 10))
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}
