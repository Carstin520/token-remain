import SwiftUI

/// Full provider quota card: brand row + plan pill, then one row per official
/// window (remaining %, progress bar, reset label). Shown in the Dashboard's
/// Limits section. Renders a waiting state before data arrives.
struct QuotaCard: View {
    /// Every card in the Dashboard grid occupies the same visual slot. The
    /// title remains pinned while a provider with extra windows scrolls inside
    /// the card instead of making its grid row taller.
    static let dashboardContentHeight: CGFloat = 198
    /// Reserve one shared title slot for every grid card so quota rows stay
    /// aligned even when a compact connection warning is present.
    private static let headerHeight: CGFloat = 26

    let provider: ProviderQuota.Provider
    let quota: ProviderQuota?
    var serviceStatus: ProviderServiceStatus?
    /// Provider 级状态说明(如 Cursor 登录过期的恢复提示)。
    var notice: String?
    static func scopedWindows(in quota: ProviderQuota) -> [ScopedQuotaWindow] {
        quota.uniqueScopedWindows
    }

    var body: some View {
        DashboardCard(padding: 13) {
            VStack(alignment: .leading, spacing: 11) {
                header
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 11) {
                        quotaContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
            .frame(height: Self.dashboardContentHeight, alignment: .top)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var quotaContent: some View {
        if let quota {
            QuotaWindowRow(
                window: quota.primary,
                provider: provider
            )
            if let secondary = quota.secondary {
                Divider().overlay(DashboardTheme.border)
                QuotaWindowRow(
                    window: secondary,
                    provider: provider
                )
            }
            ForEach(Self.scopedWindows(in: quota), id: \.scopeID) { scoped in
                Divider().overlay(DashboardTheme.border)
                QuotaWindowRow(
                    window: scoped.window,
                    provider: provider,
                    scopeName: scoped.displayName
                )
            }
            if let extraUsage = quota.extraUsage {
                Divider().overlay(DashboardTheme.border)
                ExtraUsageRow(extraUsage: extraUsage)
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
        } else if notice == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("quota.loading_official"))
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }

    }

    private var header: some View {
        let content = HStack(alignment: .top, spacing: 8) {
            BrandIcon(provider: provider)
                .foregroundStyle(DashboardTheme.text)
                .frame(width: 20, height: 20)
                .padding(.top, 3)
            Text(provider.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DashboardTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.top, 3)
                .layoutPriority(2)
            if let notice {
                QuotaConnectionNotice(message: notice)
                    .layoutPriority(1)
            }
            if let serviceStatus, serviceStatus.isAbnormal {
                ServiceStatusBadge(status: serviceStatus)
                    .padding(.top, 2)
            }
            Spacer(minLength: 4)
            if let plan = quota?.planName, !plan.isEmpty {
                TagPill(text: plan)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.headerHeight, alignment: .top)
        .contentShape(Rectangle())
        .directReorderHandle()

        return content
    }
}

/// Prominent recovery guidance pinned beside the provider name. Keeping it in
/// the fixed header makes login/install failures visible even when the quota
/// rows below need to scroll.
private struct QuotaConnectionNotice: View {
    let message: String

    var body: some View {
        Label {
            Text(L10n.text("quota.login_recovery_hint"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DashboardTheme.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DashboardTheme.warning.opacity(0.11))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(DashboardTheme.warning.opacity(0.42), lineWidth: 1)
        }
        .help(message)
        .accessibilityLabel(L10n.text("quota.login_recovery_hint"))
    }
}

/// 订阅之外的按量消费行(OpenUsage 的 "Extra Usage $X spent" 式样)。
/// 有月度上限时显示 "已花 / 上限"。
struct ExtraUsageRow: View {
    let extraUsage: ExtraUsage

    private var valueText: String {
        let spent = L10n.format("quota.spent", UsageFormatting.compactUSD(extraUsage.spentUSD))
        guard let limit = extraUsage.monthlyLimitUSD else { return spent }
        return "\(spent) / \(UsageFormatting.compactUSD(limit))"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.text("quota.extra_usage"))
                .font(.system(size: 12))
                .foregroundStyle(DashboardTheme.secondaryText)
            Spacer(minLength: 8)
            Text(valueText)
                .numericFont(12, .semibold)
                .foregroundStyle(DashboardTheme.text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A single quota window inside a `QuotaCard`.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    let provider: ProviderQuota.Provider
    var showsDetails = true
    var scopeName: String?

    private var remainingPercent: Double {
        min(100, max(0, 100 - window.usedPercent))
    }

    var body: some View {
        // 行级 60 秒一跳足够驱动配速警示与分钟级倒计时;常驻桌面的浮窗
        // 不该为秒针每秒重排整行。最后一小时的秒级滚动由重置标签内部
        // 的局部 TimelineView 单独承担。
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: showsDetails ? 7 : 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(windowTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(DashboardTheme.secondaryText)
                    Spacer()
                    if let pace = UsagePace(window: window, now: context.date),
                       pace.showsRemainingWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DashboardTheme.danger)
                            .help(L10n.text("pace.ahead_warning"))
                            .accessibilityLabel(L10n.text("pace.ahead_warning"))
                    }
                    Text(L10n.format("quota.remaining", UsageFormatting.percent(remainingPercent)))
                        .numericFont(14, .bold)
                        .foregroundStyle(DashboardTheme.text)
                }

                SegmentBar(
                    value: remainingPercent / 100,
                    accent: DashboardTheme.quotaAccent(
                        for: provider,
                        remainingPercent: remainingPercent
                    )
                )

                if showsDetails {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                        if let resetsAt = window.resetsAt {
                            QuotaResetLabel(resetsAt: resetsAt, referenceDate: context.date)
                        } else {
                            Text(L10n.text("quota.reset_pending"))
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
                provider.displayName,
                windowAccessibilityDescriptor
            )
        )
        .accessibilityValue(L10n.format("quota.remaining", UsageFormatting.percent(remainingPercent)))
    }

    private var windowTitle: String {
        let duration = L10n.format("quota.window", UsageFormatting.windowName(minutes: window.windowMinutes))
        guard let scopeName else { return duration }
        return "\(scopeName) · \(duration)"
    }

    private var windowAccessibilityDescriptor: String {
        let duration = UsageFormatting.windowName(minutes: window.windowMinutes)
        guard let scopeName else { return duration }
        return "\(scopeName) · \(duration)"
    }
}

/// 重置时间标签。距重置不足一小时才以秒级滚动倒计时;此时它是整个
/// 卡片里唯一按 1 秒刷新的叶子视图,重排被限制在这一小段文本内。
/// 一小时以上按分钟粒度显示,由外层 60 秒时间线驱动即可。
private struct QuotaResetLabel: View {
    let resetsAt: Date
    /// 外层 60 秒时间线的当前时刻,同时决定秒级/分钟级两种模式的切换。
    let referenceDate: Date

    var body: some View {
        if UsageFormatting.showsLiveSecondCountdown(to: resetsAt, now: referenceDate) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(UsageFormatting.resetDescription(to: resetsAt, now: context.date))
                    .numericFont(10)
            }
        } else {
            Text(UsageFormatting.resetDescription(to: resetsAt, now: referenceDate))
                .numericFont(10)
        }
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
