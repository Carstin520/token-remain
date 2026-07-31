import SwiftUI

struct PopoverQuotaWidget: View {
    let provider: ProviderQuota.Provider
    let quota: ProviderQuota?
    var serviceStatus: ProviderServiceStatus?
    /// Provider 级状态说明(如 Cursor 登录过期的恢复提示),数据仍在时
    /// 跟随在窗口行之后,无数据时替代加载态。
    var notice: String?
    @ObservedObject var layout: PopoverLayoutStore

    private var widget: PopoverWidget {
        PopoverWidget.allCases.first { $0.provider == provider } ?? .claude
    }

    private var isExpanded: Bool {
        layout.isExpanded(widget)
    }

    /// The Dashboard always shows verified status. The compact menu-bar
    /// surface stays quiet unless the provider needs attention.
    private var visibleServiceStatus: ProviderServiceStatus? {
        Self.visibleServiceStatus(serviceStatus)
    }

    static func visibleServiceStatus(
        _ status: ProviderServiceStatus?
    ) -> ProviderServiceStatus? {
        status?.isAbnormal == true ? status : nil
    }

    private var orderedWindows: [QuotaWindow] {
        guard let quota else { return [] }
        return [quota.primary, quota.secondary]
            .compactMap { $0 }
            .sorted { lhs, rhs in
                if lhs.windowMinutes == rhs.windowMinutes {
                    return lhs.usedPercent > rhs.usedPercent
                }
                return lhs.windowMinutes < rhs.windowMinutes
            }
    }

    static func shortestWindow(in quota: ProviderQuota?) -> QuotaWindow? {
        guard let quota else { return nil }
        return [quota.primary, quota.secondary]
            .compactMap { $0 }
            .min { $0.windowMinutes < $1.windowMinutes }
    }

    static func scopedWindows(
        in quota: ProviderQuota,
        isExpanded: Bool
    ) -> [ScopedQuotaWindow] {
        guard isExpanded else { return [] }
        return quota.uniqueScopedWindows.filter { !$0.isFable }
    }

    var body: some View {
        DashboardCard(padding: 13, cornerRadius: 13) {
            VStack(alignment: .leading, spacing: isExpanded ? 11 : 8) {
                PopoverWidgetHeader(
                    widget: widget,
                    isExpanded: isExpanded,
                    isPinned: layout.isPinned(widget),
                    onToggleExpanded: { withAnimation(.snappy) { layout.toggleExpanded(widget) } },
                    onTogglePinned: { layout.togglePinned(widget) },
                    onHide: { withAnimation(.snappy) { layout.hide(widget) } },
                    onMoveUp: { layout.moveUp(widget) },
                    onMoveDown: { layout.moveDown(widget) }
                ) {
                    if let visibleServiceStatus {
                        ServiceStatusBadge(status: visibleServiceStatus)
                    }
                }

                if let quota, let shortestWindow = orderedWindows.first {
                    // This first row is deliberately stable across both states:
                    // expanding only reveals its details and appends longer
                    // windows beneath it.
                    QuotaWindowRow(
                        window: shortestWindow,
                        provider: provider,
                        showsDetails: isExpanded
                    )

                    if isExpanded {
                        ForEach(Array(orderedWindows.dropFirst().enumerated()), id: \.offset) { _, window in
                            Divider().overlay(DashboardTheme.border)
                            QuotaWindowRow(
                                window: window,
                                provider: provider
                            )
                        }
                    }

                    ForEach(
                        Self.scopedWindows(
                            in: quota,
                            isExpanded: isExpanded
                        ),
                        id: \.scopeID
                    ) { scoped in
                        Divider().overlay(DashboardTheme.border)
                        QuotaWindowRow(
                            window: scoped.window,
                            provider: provider,
                            showsDetails: isExpanded,
                            scopeName: scoped.displayName
                        )
                    }

                    if isExpanded {
                        if let extraUsage = quota.extraUsage {
                            Divider().overlay(DashboardTheme.border)
                            ExtraUsageRow(extraUsage: extraUsage)
                        }
                        freshnessRow(quota)
                    }
                    if let notice {
                        noticeRow(notice)
                    }
                } else if let notice {
                    noticeRow(notice)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("quota.loading_official"))
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func noticeRow(_ notice: String) -> some View {
        Label(notice, systemImage: "moon.zzz.fill")
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func freshnessRow(_ quota: ProviderQuota) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let isStale = context.date.timeIntervalSince(quota.capturedAt) >= 600
            Label(
                UsageFormatting.freshnessDescription(since: quota.capturedAt, now: context.date),
                systemImage: isStale ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
            )
            .numericFont(10)
            .foregroundStyle(isStale ? DashboardTheme.warning : DashboardTheme.mutedText)
        }
    }

}
