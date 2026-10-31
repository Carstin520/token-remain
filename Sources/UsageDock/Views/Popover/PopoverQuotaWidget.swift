import SwiftUI

struct PopoverQuotaWidget: View {
    let provider: ProviderQuota.Provider
    let quota: ProviderQuota?
    var serviceStatus: ProviderServiceStatus?
    /// Provider 级状态说明(如 Cursor 登录过期的恢复提示),数据仍在时
    /// 跟随在窗口行之后,无数据时替代加载态。
    var notice: String?
    @ObservedObject var store: UsageStore
    @ObservedObject var layout: PopoverLayoutStore
    @ObservedObject var preferences: PreferencesStore = .shared
    /// Opens the claude.ai Cookie setup. Offered only on the system Claude
    /// card while it needs signing in; isolated accounts sign in elsewhere.
    var onSignInWithCookie: (() -> Void)?

    /// Speed of this provider's most-used model from local logs; nil for
    /// providers without a log reader or without enough timed responses.
    private var modelSpeed: ModelSpeedSummary? {
        ModelSpeedSummary.make(
            history: store.history,
            throughput: store.modelThroughput,
            agentID: provider.ccusageAgentID
        )
    }

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

    private var enabledAccounts: [ProviderAccountSnapshot] {
        store.accountSnapshots(for: provider).filter(\.profile.isEnabled)
    }

    /// A lone system login keeps the original single-quota card. Extra signed-in
    /// accounts earn their own rows so the menu-bar panel matches Limits.
    private var showsAccountRows: Bool {
        Self.showsAccountRows(enabledAccounts)
    }

    static func showsAccountRows(_ snapshots: [ProviderAccountSnapshot]) -> Bool {
        snapshots.filter(\.profile.isEnabled).count > 1
    }

    private var orderedWindows: [(window: QuotaWindow, remainingBalance: QuotaBalance?)] {
        Self.orderedWindows(in: quota)
    }

    static func orderedWindows(
        in quota: ProviderQuota?
    ) -> [(window: QuotaWindow, remainingBalance: QuotaBalance?)] {
        guard let quota else { return [] }
        var windows = [(
            window: quota.primary,
            remainingBalance: quota.primary.remainingBalance ?? quota.remainingBalance
        )]
        if let secondary = quota.secondary {
            windows.append((window: secondary, remainingBalance: secondary.remainingBalance))
        }
        return windows
            .sorted { lhs, rhs in
                if lhs.window.windowMinutes == rhs.window.windowMinutes {
                    return lhs.window.usedPercent > rhs.window.usedPercent
                }
                return lhs.window.windowMinutes < rhs.window.windowMinutes
            }
    }

    static func shortestWindow(in quota: ProviderQuota?) -> QuotaWindow? {
        guard let quota else { return nil }
        return [quota.primary, quota.secondary]
            .compactMap { $0 }
            .min { $0.windowMinutes < $1.windowMinutes }
    }

    /// 目录内的池(Fable/Spark/3P/MiMo 日池等)由通用池开关 + 智能默认
    /// 决定显隐;目录外的池(账户级兄弟池)维持既有行为——跟随展开态。
    /// Fable 依旧不跟随 isExpanded(entry.followsExpansion == false):它往往
    /// 先于 all-models 额度耗尽,收起态藏掉它就等于藏掉真正的瓶颈。
    @MainActor
    static func scopedWindows(
        in quota: ProviderQuota,
        isExpanded: Bool,
        preferences: PreferencesStore
    ) -> [ScopedQuotaWindow] {
        quota.uniqueScopedWindows.filter { scoped in
            guard let entry = ScopedPoolToggleCatalog.entry(
                for: scoped,
                provider: quota.provider
            ) else {
                return isExpanded
            }
            if entry.followsExpansion && !isExpanded { return false }
            // 活跃度按整个池组判定(见 ScopedPoolToggleCatalog.poolIsActive),
            // 同组多行(如 Spark 的 _session/_weekly)显隐一致,且与设置页
            // 开关读到的智能默认相同。
            return preferences.resolvedScopedPoolVisibility(
                provider: entry.provider,
                poolKey: entry.poolKey,
                poolIsActive: ScopedPoolToggleCatalog.poolIsActive(
                    entry: entry,
                    in: quota
                )
            )
        }
    }

    var body: some View {
        DashboardCard(padding: 13, cornerRadius: 13, interactive: true) {
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

                if showsAccountRows {
                    ForEach(Array(enabledAccounts.enumerated()), id: \.element.id) { index, snapshot in
                        if index > 0 {
                            Divider().overlay(DashboardSurface.border)
                        }
                        // Local logs cannot tell accounts apart, so the speed
                        // appears once, on the first account.
                        accountQuotaContent(snapshot, showsModelSpeed: index == 0)
                    }
                } else if let quota, let shortestWindow = orderedWindows.first {
                    quotaContent(
                        quota,
                        shortestWindow: shortestWindow,
                        remainingWindows: Array(orderedWindows.dropFirst()),
                        accountName: nil,
                        trailingNotice: notice,
                        offersCookieSignIn: offersCookieSignIn,
                        modelSpeed: modelSpeed
                    )
                } else if let notice {
                    noticeRow(notice, offersCookieSignIn: offersCookieSignIn)
                } else {
                    loadingRow
                }
            }
        }
        // Reset, pace and speed lines read at 11 pt on the popup's glass.
        .environment(\.quotaDetailFontSize, 11)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func accountQuotaContent(
        _ snapshot: ProviderAccountSnapshot,
        showsModelSpeed: Bool
    ) -> some View {
        if let quota = snapshot.quota {
            let windows = Self.orderedWindows(in: quota)
            if let shortestWindow = windows.first {
                quotaContent(
                    quota,
                    shortestWindow: shortestWindow,
                    remainingWindows: Array(windows.dropFirst()),
                    accountName: Self.accountCaption(for: snapshot, among: enabledAccounts),
                    trailingNotice: snapshot.notice,
                    modelSpeed: showsModelSpeed ? modelSpeed : nil
                )
            } else if let notice = snapshot.notice, !notice.isEmpty {
                accountStatusRow(
                    name: snapshot.profile.accountDisplayName,
                    text: notice,
                    isRefreshing: snapshot.isRefreshing
                )
            }
        } else {
            accountStatusRow(
                name: snapshot.profile.accountDisplayName,
                text: L10n.text(
                    snapshot.isRefreshing ? "accounts.refreshing" : "accounts.unavailable"
                ),
                isRefreshing: snapshot.isRefreshing,
                notice: snapshot.notice
            )
        }
    }

    @ViewBuilder
    private func quotaContent(
        _ quota: ProviderQuota,
        shortestWindow: (window: QuotaWindow, remainingBalance: QuotaBalance?),
        remainingWindows: [(window: QuotaWindow, remainingBalance: QuotaBalance?)],
        accountName: String?,
        trailingNotice: String?,
        offersCookieSignIn: Bool = false,
        modelSpeed: ModelSpeedSummary? = nil
    ) -> some View {
        // A second account names itself once, in small print above its
        // rows, so two Claude logins cannot collapse into unlabeled bars
        // without repeating the name on every bar.
        if let accountName {
            accountCaption(accountName)
        }
        // This first row is deliberately stable across both states:
        // expanding only reveals its details and appends longer
        // windows beneath it.
        QuotaWindowRow(
            window: shortestWindow.window,
            provider: provider,
            attribution: quota.attribution,
            showsDetails: isExpanded,
            remainingBalance: shortestWindow.remainingBalance,
            modelSpeed: modelSpeed,
            vendorSummary: quota.modelVendorSummary(for: shortestWindow.window)
        )

        if isExpanded {
            ForEach(Array(remainingWindows.enumerated()), id: \.offset) { _, item in
                Divider().overlay(DashboardSurface.border)
                QuotaWindowRow(
                    window: item.window,
                    provider: provider,
                    attribution: quota.attribution,
                    remainingBalance: item.remainingBalance,
                    vendorSummary: quota.modelVendorSummary(for: item.window)
                )
            }
        }

        ForEach(
            Self.scopedWindows(
                in: quota,
                isExpanded: isExpanded,
                preferences: preferences
            ),
            id: \.scopeID
        ) { scoped in
            Divider().overlay(DashboardSurface.border)
            QuotaWindowRow(
                window: scoped.window,
                provider: provider,
                attribution: quota.attribution,
                showsDetails: isExpanded,
                scopeName: scoped.displayName,
                vendorSummary: quota.modelVendorSummary(for: scoped.window, scopedName: scoped.displayName)
            )
        }

        if isExpanded {
            if let extraUsage = quota.extraUsage {
                Divider().overlay(DashboardSurface.border)
                ExtraUsageRow(extraUsage: extraUsage)
            }
            if let balance = quota.accountBalance {
                Divider().overlay(DashboardSurface.border)
                AccountBalanceRow(balance: balance)
            }
            if let spend = quota.spend, spend.hasValues {
                Divider().overlay(DashboardSurface.border)
                ProviderSpendRow(spend: spend)
            }
            freshnessRow(quota)
        }
        if let trailingNotice {
            noticeRow(trailingNotice, offersCookieSignIn: offersCookieSignIn)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.text("quota.loading_official"))
                .font(.system(size: 11))
                .usageDockAdaptiveForeground(.secondary)
        }
    }

    private func accountStatusRow(
        name: String,
        text: String,
        isRefreshing: Bool,
        notice: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView().controlSize(.mini)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13))
                    .usageDockAdaptiveForeground(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(text)
                    .font(.system(size: 11))
                    .usageDockAdaptiveForeground(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .help(notice ?? text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.format("accounts.row_accessibility", provider.displayName, name)
        )
        .accessibilityValue(text)
    }

    /// The name above an account's rows. A lone account needs none, and when
    /// there are several the default (system) login stays unnamed.
    static func accountCaption(
        for snapshot: ProviderAccountSnapshot,
        among snapshots: [ProviderAccountSnapshot]
    ) -> String? {
        guard showsAccountRows(snapshots), !snapshot.profile.isSystem else { return nil }
        return snapshot.profile.accountDisplayName
    }

    private func accountCaption(_ name: String) -> some View {
        Text(verbatim: name)
            .font(.system(size: 11, weight: .medium))
            .usageDockAdaptiveForeground(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(name)
            .accessibilityAddTraits(.isHeader)
    }

    private var offersCookieSignIn: Bool {
        provider == .claude && store.claudeNeedsSignIn && onSignInWithCookie != nil
    }

    @ViewBuilder
    private func noticeRow(_ notice: String, offersCookieSignIn: Bool = false) -> some View {
        Label(notice, systemImage: "moon.zzz.fill")
            .font(.system(size: 11))
            .usageDockAdaptiveForeground(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if offersCookieSignIn, let onSignInWithCookie {
            Button(L10n.text("claude.web.sign_in_with_cookie"), action: onSignInWithCookie)
                .controlSize(.small)
        }
        if store.keychainAuthorizationRequired.contains(provider) {
            KeychainAuthorizationButton(store: store, provider: provider)
        }
    }

    private func freshnessRow(_ quota: ProviderQuota) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let isStale = context.date.timeIntervalSince(quota.capturedAt) >= 600
            Label(
                UsageFormatting.freshnessDescription(since: quota.capturedAt, now: context.date),
                systemImage: isStale ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
            )
            .numericFont(11)
            .usageDockAdaptiveForeground(
                .muted,
                fixedColor: isStale ? DashboardTheme.warning : nil
            )
        }
    }

}
