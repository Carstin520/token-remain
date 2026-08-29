import SwiftUI

/// Full provider quota card: brand row + plan pill, then one row per official
/// window (remaining %, progress bar, reset label). Shown in the Dashboard's
/// Limits section. Renders a waiting state before data arrives.
struct QuotaCard: View {
    /// Every card in the Dashboard grid occupies the same visual slot. Keep the
    /// provider header pinned and let extra quota windows scroll inside the card
    /// so one multi-window provider cannot make the whole grid row taller.
    static let dashboardContentHeight: CGFloat = 198
    /// Reserve one shared title slot for every grid card so quota rows stay
    /// aligned even when a compact connection warning is present.
    private static let headerHeight: CGFloat = 26

    let provider: ProviderQuota.Provider
    let quota: ProviderQuota?
    var serviceStatus: ProviderServiceStatus?
    /// Provider 级状态说明(如 Cursor 登录过期的恢复提示)。
    var notice: String?
    /// Supplied by Dashboard Limits so manually configured providers can be
    /// connected in-place on their first empty quota card.
    var store: UsageStore? = nil
    @ObservedObject var preferences: PreferencesStore = .shared

    /// Managed-account alerts are card-local: renaming and removal must not open
    /// another window or settings route.
    @State private var pendingRenameID: ProviderAccountID?
    @State private var pendingRenameText = ""
    @State private var pendingRemoveID: ProviderAccountID?
    /// Every provider presents its setup requirements before starting login or
    /// accepting a secret, so the compact plus button never triggers a surprise.
    @State private var isPresentingAccountSetup = false
    @State private var pendingCredentialUpdateID: ProviderAccountID?
    /// 实测的滚动视口与内容高度。卡片槽位固定(网格对齐),但内容装得下
    /// 时不该出现滚动条+大片留白的矛盾观感(#42:Codex Plus 用户没有
    /// Spark 行,内容其实放得下)。测量驱动而非按 provider 硬编码,之后
    /// 任何新窗口行(如模型池 5h)把内容顶超槽位时滚动会自动恢复。
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0

    /// 首帧测量未落地时(0/0)按"装得下"处理,避免加载态闪一下滚动条。
    private var quotaContentFits: Bool {
        scrollContentHeight <= scrollViewportHeight + 0.5
    }

    /// #44:只有一条额度窗口(可带 Codex 重置卡)的极简配置,内容高度有
    /// 天然上界,卡片直接按内容定高、整体不滚动——重置卡把内容顶出固定
    /// 槽位时长高卡片而不是出滚动条。多窗口/多账户配置仍走固定槽位+
    /// 滚动,避免单个多池 provider 抬高整行网格。
    private var usesBoundedContentLayout: Bool {
        guard let quota, !showsAccountOverview else { return false }
        if let store, store.isAddingProviderAccount(provider) { return false }
        return quota.secondary == nil
            && Self.scopedWindows(in: quota, preferences: preferences).isEmpty
            && quota.extraUsage == nil
            && quota.accountBalance == nil
            && !(quota.spend?.hasValues ?? false)
    }

    /// Dashboard 卡片:目录内的池由通用池开关 + 智能默认决定显隐;
    /// 目录外的池(账户级兄弟池)维持既有行为——恒显。
    @MainActor
    static func scopedWindows(
        in quota: ProviderQuota,
        preferences: PreferencesStore
    ) -> [ScopedQuotaWindow] {
        quota.uniqueScopedWindows.filter { scoped in
            guard let entry = ScopedPoolToggleCatalog.entry(
                for: scoped,
                provider: quota.provider
            ) else {
                return true
            }
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

    private var credentialConfiguration: ProviderCredentialConfiguration? {
        guard quota == nil else { return nil }
        return ProviderCredentialConfiguration.resolve(for: provider)
    }

    var body: some View {
        DashboardCard(padding: 13) {
            VStack(alignment: .leading, spacing: 11) {
                header
                if usesBoundedContentLayout {
                    VStack(alignment: .leading, spacing: 11) {
                        quotaContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 11) {
                            quotaContent
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(heightReader { scrollContentHeight = $0 })
                    }
                    .scrollDisabled(quotaContentFits)
                    .scrollIndicators(quotaContentFits ? .hidden : .automatic)
                    .background(heightReader { scrollViewportHeight = $0 })
                }
            }
            .frame(
                minHeight: Self.dashboardContentHeight,
                maxHeight: usesBoundedContentLayout ? nil : Self.dashboardContentHeight,
                alignment: .top
            )
        }
        .accessibilityElement(children: .contain)
        .alert(
            L10n.text("accounts.rename_title"),
            isPresented: renameAlertPresented,
            presenting: pendingRenameID
        ) { id in
            TextField(L10n.text("accounts.rename_placeholder"), text: $pendingRenameText)
            Button(L10n.text("action.cancel"), role: .cancel) { pendingRenameID = nil }
            Button(L10n.text("action.save")) {
                store?.renameProviderAccount(id, to: pendingRenameText)
                pendingRenameID = nil
            }
        } message: { _ in
            Text(L10n.text("accounts.rename_message"))
        }
        .alert(
            L10n.text("accounts.remove_title"),
            isPresented: removeAlertPresented,
            presenting: pendingRemoveID
        ) { id in
            Button(L10n.text("action.cancel"), role: .cancel) { pendingRemoveID = nil }
            Button(L10n.text("accounts.remove_confirm"), role: .destructive) {
                store?.removeProviderAccount(id)
                pendingRemoveID = nil
            }
        } message: { id in
            Text(L10n.format(removeMessageKey(for: id), accountName(for: id)))
        }
    }

    /// 尺寸测量探针:铺在被测视图的 background 里,不参与命中与布局。
    private func heightReader(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, newValue in update(newValue) }
        }
    }

    /// An isolated CLI account owns a local login folder; a keychain account
    /// owns one Keychain item. Say which one removal actually deletes.
    private func removeMessageKey(for id: ProviderAccountID) -> String {
        let kind = accountSnapshots.first { $0.id == id }?.profile.credentialKind
        return kind == .keychainSecret
            ? "accounts.remove_message_credential"
            : "accounts.remove_message"
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingRenameID != nil },
            set: { if !$0 { pendingRenameID = nil } }
        )
    }

    private var removeAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingRemoveID != nil },
            set: { if !$0 { pendingRemoveID = nil } }
        )
    }

    @ViewBuilder
    private var quotaContent: some View {
        if supportsMultipleAccounts, let store,
           store.isAddingProviderAccount(provider) {
            AccountAddProgressRow(credentialKind: multiAccountCapability?.credentialKind)
        }

        if showsAccountOverview {
            accountOverview
        } else {
            singleAccountContent
        }
    }

    @ViewBuilder
    private var singleAccountContent: some View {
        if let quota {
            if provider == .codex, let credits = quota.codexResetCredits {
                CodexResetCreditsCard(credits: credits)
                Divider().overlay(DashboardSurface.border)
            }
            QuotaWindowRow(
                window: quota.primary,
                provider: provider,
                attribution: quota.attribution,
                remainingBalance: quota.primary.remainingBalance ?? quota.remainingBalance
            )
            if let secondary = quota.secondary {
                Divider().overlay(DashboardSurface.border)
                QuotaWindowRow(
                    window: secondary,
                    provider: provider,
                    attribution: quota.attribution
                )
            }
            ForEach(
                Self.scopedWindows(in: quota, preferences: preferences),
                id: \.scopeID
            ) { scoped in
                Divider().overlay(DashboardSurface.border)
                QuotaWindowRow(
                    window: scoped.window,
                    provider: provider,
                    attribution: quota.attribution,
                    scopeName: scoped.displayName
                )
            }
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
        } else if let credentialConfiguration, let store {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    L10n.text(
                        credentialConfiguration.isCookie
                            ? "provider.detect.needs_cookie_hint"
                            : "provider.detect.needs_api_key_hint"
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                ProviderCredentialEntryRow(
                    store: store,
                    provider: provider,
                    configuration: credentialConfiguration
                )

                if let notice {
                    Text(notice)
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.warning)
                        .lineLimit(2)
                        .help(notice)
                }
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
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 8) {
                BrandIcon(provider: provider)
                    .foregroundStyle(DashboardTheme.text)
                    .frame(width: 20, height: 20)
                Text(provider.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(2)
            }
            .padding(.top, 3)
            .directReorderHandle()

            // Deliberately outside every `directReorderHandle` region so the
            // menu and the add button never start a card drag.
            accountControls

            if let notice, credentialConfiguration == nil {
                QuotaConnectionNotice(message: notice)
                    .layoutPriority(1)
            }
            if let serviceStatus, serviceStatus.isAbnormal {
                ServiceStatusBadge(status: serviceStatus)
                    .padding(.top, 2)
            }

            Color.clear
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
                .directReorderHandle()

            if let plan = quota?.planName, !plan.isEmpty {
                TagPill(text: plan)
                    .padding(.top, 2)
                    .directReorderHandle()
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: Self.headerHeight,
            maxHeight: Self.headerHeight,
            alignment: .top
        )
        .contentShape(Rectangle())
    }

    // MARK: - Multi-account

    /// The backend decides which providers expose a safe credential boundary.
    /// Providers without one (currently OpenCode and Kiro) keep exactly their
    /// previous header and content, including the absence of an Add button.
    private var multiAccountCapability: ProviderMultiAccountCapability? {
        store == nil ? nil : provider.multiAccountCapability
    }

    private var supportsMultipleAccounts: Bool {
        multiAccountCapability != nil
    }

    /// Non-nil only for providers whose second account is one opaque secret;
    /// isolated-CLI providers sign in through their own official browser flow.
    private var credentialHint: ProviderAccountCredentialHint? {
        guard multiAccountCapability?.credentialKind == .keychainSecret else { return nil }
        return ProviderAccountCredentialHint.resolve(for: provider)
    }

    /// Includes disabled managed accounts on purpose: a paused account must stay
    /// discoverable in the menu even though it leaves the all-account summary.
    private var accountSnapshots: [ProviderAccountSnapshot] {
        guard supportsMultipleAccounts, let store else { return [] }
        return store.accountSnapshots(for: provider)
    }

    private var accountSelection: ProviderAccountSelection {
        store?.accountSelection(for: provider) ?? .all
    }

    private var selectedAccount: ProviderAccountSnapshot? {
        guard case .account(let id) = accountSelection else { return nil }
        return accountSnapshots.first { $0.id == id }
    }

    /// A lone system account keeps the original single-account card. The grouped
    /// summary only earns its space once a second account exists.
    private var showsAccountOverview: Bool {
        guard supportsMultipleAccounts, case .all = accountSelection else { return false }
        return accountSnapshots.count > 1
    }

    private func accountName(for id: ProviderAccountID) -> String {
        accountSnapshots.first { $0.id == id }?.profile.accountDisplayName
            ?? L10n.text("accounts.untitled")
    }

    @ViewBuilder
    private var accountControls: some View {
        if supportsMultipleAccounts, let store {
            HStack(spacing: 5) {
                if accountSnapshots.count > 1 {
                    accountMenu(store: store)
                }
                addAccountButton(store: store)
            }
            .padding(.top, 2)
            // Anchored to the row rather than the button so the form stays put
            // while the button itself is disabled during verification.
            .popover(isPresented: $isPresentingAccountSetup, arrowEdge: .bottom) {
                if multiAccountCapability?.credentialKind == .isolatedCLI {
                    AddCLIProviderAccountSheet(
                        store: store,
                        provider: provider,
                        isPresented: $isPresentingAccountSetup
                    )
                } else if let hint = credentialHint {
                    AddProviderAccountSheet(
                        store: store,
                        provider: provider,
                        hint: hint,
                        editingProfile: pendingCredentialUpdateID.flatMap { id in
                            accountSnapshots.first { $0.id == id }?.profile
                        },
                        isPresented: $isPresentingAccountSetup
                    )
                }
            }
            .onChange(of: isPresentingAccountSetup) { _, isPresented in
                if !isPresented {
                    pendingCredentialUpdateID = nil
                    store.clearAccountManagementNotice(for: provider)
                }
            }
        }
    }

    private func accountMenu(store: UsageStore) -> some View {
        let selection = accountSelection
        let isAll = selection == .all
        let summary = store.accountSummary(for: provider)
        let label = isAll
            ? L10n.format("accounts.chip_all", summary.accountCount)
            : (selectedAccount?.profile.accountDisplayName ?? L10n.text("accounts.untitled"))

        return Menu {
            Button {
                store.setAccountSelection(.all, for: provider)
            } label: {
                Label(L10n.text("accounts.all"), systemImage: isAll ? "checkmark" : "person.2")
            }
            Divider()
            ForEach(accountSnapshots) { snapshot in
                Menu {
                    accountActions(snapshot, store: store)
                } label: {
                    Label(
                        snapshot.profile.isEnabled
                            ? snapshot.profile.accountDisplayName
                            : L10n.format("accounts.entry_disabled", snapshot.profile.accountDisplayName),
                        systemImage: menuGlyph(for: snapshot, selection: selection)
                    )
                }
            }
            Divider()
            Button {
                addAccount(store: store)
            } label: {
                Label(L10n.text("accounts.add"), systemImage: "plus")
            }
            .disabled(store.isAddingProviderAccount(provider))
        } label: {
            HStack(spacing: 4) {
                if selectedAccount?.isRefreshing == true {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isAll ? "person.2.fill" : "person.crop.circle.fill")
                        .font(.system(size: 9))
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 78, alignment: .leading)
            }
            .foregroundStyle(DashboardTheme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DashboardSurface.surface2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DashboardSurface.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.format("accounts.menu_help", provider.displayName))
        .accessibilityLabel(L10n.format("accounts.menu_accessibility", provider.displayName, label))
    }

    private func menuGlyph(
        for snapshot: ProviderAccountSnapshot,
        selection: ProviderAccountSelection
    ) -> String {
        if selection == .account(snapshot.id) { return "checkmark" }
        if !snapshot.profile.isEnabled { return "person.crop.circle.badge.xmark" }
        return "person.crop.circle"
    }

    private func addAccountButton(store: UsageStore) -> some View {
        Button {
            addAccount(store: store)
        } label: {
            Group {
                if store.isAddingProviderAccount(provider) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DashboardTheme.secondaryText)
                }
            }
            .frame(width: 20, height: 18)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DashboardSurface.surface2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DashboardSurface.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(store.isAddingProviderAccount(provider))
        .help(
            store.isAddingProviderAccount(provider)
                ? L10n.text(addingLabelKey)
                : L10n.format(addHelpKey, provider.displayName)
        )
        .accessibilityLabel(L10n.format("accounts.add_accessibility", provider.displayName))
    }

    private var addHelpKey: String {
        multiAccountCapability?.credentialKind == .keychainSecret
            ? "accounts.add_help_credential"
            : "accounts.add_help"
    }

    private var addingLabelKey: String {
        multiAccountCapability?.credentialKind == .keychainSecret
            ? "accounts.adding_credential"
            : "accounts.adding"
    }

    /// The store already guards against a second concurrent add; checking here
    /// too keeps a double click from queueing a redundant sign-in. Isolated-CLI
    /// providers now explain the isolated browser login before it starts;
    /// keychain providers explain exactly which credential will be stored.
    private func addAccount(store: UsageStore) {
        guard !store.isAddingProviderAccount(provider) else { return }
        guard multiAccountCapability != nil else { return }
        pendingCredentialUpdateID = nil
        store.clearAccountManagementNotice(for: provider)
        isPresentingAccountSetup = true
    }

    @ViewBuilder
    private var accountOverview: some View {
        if let store {
            let summary = store.accountSummary(for: provider)
            let enabled = accountSnapshots.filter(\.profile.isEnabled)

            HStack(spacing: 8) {
                Text(L10n.format(
                    "accounts.summary_available",
                    summary.availableCount,
                    summary.accountCount
                ))
                .numericFont(10.5, .semibold)
                .foregroundStyle(DashboardTheme.secondaryText)
                Spacer(minLength: 6)
                if summary.lowAccountCount > 0 {
                    Text(L10n.format("accounts.summary_low", summary.lowAccountCount))
                        .numericFont(10.5, .semibold)
                        .foregroundStyle(DashboardTheme.warning)
                }
                if let lowest = summary.lowestRemainingPercent {
                    Text(L10n.format("accounts.summary_lowest", UsageFormatting.percent(lowest)))
                        .numericFont(10.5, .semibold)
                        .foregroundStyle(DashboardTheme.text)
                }
            }

            ForEach(summary.balancesByCurrency.keys.sorted(), id: \.self) { currency in
                HStack {
                    Text(L10n.format("accounts.balance_combined", currency))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.secondaryText)
                    Spacer()
                    Text(QuotaBalance(
                        amount: summary.balancesByCurrency[currency] ?? 0,
                        currencyCode: currency
                    ).displayText)
                    .numericFont(11, .semibold)
                    .foregroundStyle(DashboardTheme.text)
                }
            }

            ForEach(enabled) { snapshot in
                Divider().overlay(DashboardSurface.border)
                AccountDigestRow(
                    snapshot: snapshot,
                    provider: provider,
                    select: { store.setAccountSelection(.account(snapshot.id), for: provider) }
                )
                .contextMenu { accountActions(snapshot, store: store) }
            }

            if enabled.isEmpty {
                Text(L10n.text("accounts.all_disabled"))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func accountActions(
        _ snapshot: ProviderAccountSnapshot,
        store: UsageStore
    ) -> some View {
        Button {
            store.setAccountSelection(.account(snapshot.id), for: provider)
        } label: {
            Label(L10n.text("accounts.show_only"), systemImage: "person.crop.circle")
        }
        Button {
            Task { await store.refreshProviderAccount(snapshot.id) }
        } label: {
            Label(L10n.text("action.refresh"), systemImage: "arrow.clockwise")
        }
        .disabled(snapshot.isRefreshing || !snapshot.profile.isEnabled)

        // The system account mirrors this Mac's own login for the provider, so
        // TokenRemain must not rename, pause, or delete it.
        if !snapshot.profile.isSystem {
            Divider()
            if snapshot.profile.credentialKind == .keychainSecret {
                Button {
                    pendingCredentialUpdateID = snapshot.id
                    store.clearAccountManagementNotice(for: provider)
                    isPresentingAccountSetup = true
                } label: {
                    Label(L10n.text("accounts.update_credential"), systemImage: "key.fill")
                }
            }
            Button {
                pendingRenameText = snapshot.profile.accountDisplayName
                pendingRenameID = snapshot.id
            } label: {
                Label(L10n.text("accounts.rename"), systemImage: "pencil")
            }
            Button {
                setAccountEnabled(!snapshot.profile.isEnabled, snapshot: snapshot, store: store)
            } label: {
                Label(
                    L10n.text(snapshot.profile.isEnabled ? "accounts.disable" : "accounts.enable"),
                    systemImage: snapshot.profile.isEnabled ? "pause.circle" : "play.circle"
                )
            }
            Divider()
            Button(role: .destructive) {
                pendingRemoveID = snapshot.id
            } label: {
                Label(L10n.text("accounts.remove"), systemImage: "trash")
            }
        }
    }

    /// Pausing the account the card is currently showing would leave the card on
    /// a stale reading, so fall back to the all-account view in the same click.
    private func setAccountEnabled(
        _ enabled: Bool,
        snapshot: ProviderAccountSnapshot,
        store: UsageStore
    ) {
        if !enabled, accountSelection == .account(snapshot.id) {
            store.setAccountSelection(.all, for: provider)
        }
        store.setProviderAccountEnabled(enabled, id: snapshot.id)
    }
}

private extension ProviderAccountProfile {
    /// The system account has no stored name and a managed account can only be
    /// renamed to a non-empty string, so this is the single naming fallback.
    var accountDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return L10n.text(isSystem ? "accounts.system" : "accounts.untitled")
    }
}

/// One enabled account inside the all-account view: its own lowest remaining
/// window, independent of whether any sibling account failed. Clicking it opens
/// that account's full quota rows in the same card.
private struct AccountDigestRow: View {
    let snapshot: ProviderAccountSnapshot
    let provider: ProviderQuota.Provider
    let select: () -> Void

    private var summary: ProviderQuota.GeneralQuotaSummary? {
        snapshot.quota?.generalQuotaSummary(strategy: .lowestRemaining)
    }

    private var valueText: String {
        guard let summary else {
            return L10n.text(snapshot.isRefreshing ? "accounts.refreshing" : "accounts.unavailable")
        }
        return L10n.format(
            "quota.remaining",
            QuotaWindowRow.remainingValueText(
                remainingPercent: summary.remainingPercent,
                remainingBalance: summary.remainingBalance
            )
        )
    }

    private var valueTint: Color {
        guard let summary else {
            return snapshot.isRefreshing ? DashboardTheme.secondaryText : DashboardTheme.warning
        }
        return summary.remainingPercent < 10 ? DashboardTheme.danger : DashboardTheme.text
    }

    private var windowText: String? {
        summary.map { UsageFormatting.windowName(minutes: $0.window.windowMinutes) }
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.mutedText)
                Text(snapshot.profile.accountDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let windowText {
                    Text(windowText)
                        .numericFont(10)
                        .foregroundStyle(DashboardTheme.mutedText)
                        .lineLimit(1)
                }
                if snapshot.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else if snapshot.quota == nil, let notice = snapshot.notice, !notice.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DashboardTheme.warning)
                        .help(notice)
                }
                Spacer(minLength: 8)
                Text(valueText)
                    .numericFont(12, .semibold)
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("accounts.row_help"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.format(
                "accounts.row_accessibility",
                provider.displayName,
                snapshot.profile.accountDisplayName
            )
        )
        .accessibilityValue(valueText)
        .accessibilityHint(L10n.text("accounts.row_help"))
        .accessibilityAddTraits(.isButton)
    }
}

/// Official browser sign-in runs outside the app and credential checks run
/// against the provider, so the card states plainly which one it is waiting on
/// instead of looking frozen.
private struct AccountAddProgressRow: View {
    let credentialKind: ProviderAccountCredentialKind?

    private var messageKey: String {
        credentialKind == .keychainSecret
            ? "accounts.adding_progress_credential"
            : "accounts.adding_progress"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.text(messageKey))
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text(messageKey))
    }
}

/// Codex's banked rate-limit reset balance lives inside the Codex quota card so
/// it stays attached to the limit it can restore. The official usage response
/// exposes the banked count but not a per-credit expiry timestamp. OpenAI's
/// documented app-server contract calls `availableCount` authoritative, while
/// actual redemption can still return `nothingToReset` when no window qualifies.
/// Show the balance here and leave redemption eligibility to Codex Usage.
struct CodexResetCreditsCard: View {
    let credits: CodexRateLimitResetCredits

    static let managementURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

    var hasAvailableReset: Bool {
        credits.availableCount > 0
    }

    var statusText: String {
        guard credits.availableCount > 0 else {
            return L10n.text("codex.reset_credits.empty")
        }
        return L10n.format("codex.reset_credits.available_balance", credits.availableCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        hasAvailableReset
                            ? DashboardTheme.success
                            : DashboardTheme.mutedText
                    )
                Text(L10n.text("codex.reset_credits.title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Spacer(minLength: 8)
                Text(statusText)
                    .numericFont(11, .semibold)
                    .foregroundStyle(
                        hasAvailableReset
                            ? DashboardTheme.success
                            : DashboardTheme.secondaryText
                    )
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    L10n.text("codex.reset_credits.expiration"),
                    systemImage: "calendar.badge.clock"
                )
                .font(.system(size: 9.5))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)

                Link(destination: Self.managementURL) {
                    HStack(spacing: 3) {
                        Text(L10n.text("codex.reset_credits.manage"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(DashboardTheme.link)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DashboardSurface.surface2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(DashboardSurface.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(L10n.text("codex.reset_credits.title")), \(statusText), \(L10n.text("codex.reset_credits.expiration"))"
        )
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
                .usageDockAdaptiveForeground(.secondary)
            Spacer(minLength: 8)
            Text(valueText)
                .numericFont(12, .semibold)
                .usageDockAdaptiveForeground(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact official spend summary used by providers such as OpenRouter. A
/// missing bucket remains hidden instead of looking like a real $0 reading.
struct ProviderSpendRow: View {
    let spend: ProviderSpend

    private var items: [(String, Double)] {
        [
            (L10n.text("usage.spend_today"), spend.todayUSD),
            (L10n.text("quota.spend_week"), spend.weekUSD),
            (L10n.text("quota.spend_month"), spend.monthUSD),
            (L10n.text("quota.spend_all_time"), spend.allTimeUSD)
        ].compactMap { label, value in
            guard let value, value.isFinite else { return nil }
            return (label, max(0, value))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("quota.official_spend"))
                .font(.system(size: 12))
                .usageDockAdaptiveForeground(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.0)
                        .font(.system(size: 10.5))
                        .usageDockAdaptiveForeground(.secondary)
                    Spacer(minLength: 8)
                    Text(UsageFormatting.compactUSD(item.1))
                        .numericFont(10.5, .semibold)
                        .usageDockAdaptiveForeground(.primary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AccountBalanceRow: View {
    let balance: QuotaBalance

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.text("quota.account_balance"))
                .font(.system(size: 12))
                .usageDockAdaptiveForeground(.secondary)
            Spacer(minLength: 8)
            Text(balance.displayText)
                .numericFont(12, .semibold)
                .usageDockAdaptiveForeground(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A single quota window inside a `QuotaCard`.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    let provider: ProviderQuota.Provider
    var attribution: QuotaAttribution? = nil
    var showsDetails = true
    var scopeName: String?
    var remainingBalance: QuotaBalance? = nil

    /// Scoped rows are named by their call site; a general window can also
    /// name itself when it represents one pool of a split cycle (Cursor).
    private var effectiveScopeName: String? {
        scopeName ?? window.poolName
    }

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
                    if let sourceProvider = attribution?.provider,
                       sourceProvider != provider {
                        BrandIcon(provider: sourceProvider)
                            .frame(width: 12, height: 12)
                            .usageDockAdaptiveForeground(.secondary)
                    }
                    Text(windowTitle)
                        .font(.system(size: 13))
                        .usageDockAdaptiveForeground(.secondary)
                    Spacer()
                    if let pace = UsagePace(window: window, now: context.date),
                       pace.showsRemainingWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DashboardTheme.danger)
                            .help(L10n.text("pace.ahead_warning"))
                            .accessibilityLabel(L10n.text("pace.ahead_warning"))
                    }
                    Text(remainingText)
                        .numericFont(14, .bold)
                        .usageDockAdaptiveForeground(.primary)
                }

                SegmentBar(
                    value: remainingPercent / 100,
                    accent: DashboardTheme.quotaAccent(
                        for: attribution?.provider ?? provider,
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
                    .usageDockAdaptiveForeground(.secondary)
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
                accessibilityProviderName,
                windowAccessibilityDescriptor
            )
        )
        .accessibilityValue(remainingText)
    }

    private var remainingText: String {
        L10n.format(
            "quota.remaining",
            Self.remainingValueText(
                remainingPercent: remainingPercent,
                remainingBalance: remainingBalance ?? window.remainingBalance
            )
        )
    }

    static func remainingValueText(
        remainingPercent: Double,
        remainingBalance: QuotaBalance?
    ) -> String {
        remainingBalance?.displayText ?? UsageFormatting.percent(remainingPercent)
    }

    private var windowTitle: String {
        Self.displayTitle(
            windowMinutes: window.windowMinutes,
            scopeName: effectiveScopeName,
            attribution: attribution
        )
    }

    static func displayTitle(
        windowMinutes: Int,
        scopeName: String?,
        attribution: QuotaAttribution?
    ) -> String {
        let duration = L10n.format("quota.window", UsageFormatting.windowName(minutes: windowMinutes))
        let scoped = scopeName.map { "\($0) · \(duration)" } ?? duration
        guard let source = attribution?.displayName else { return scoped }
        return "\(source) · \(scoped)"
    }

    private var windowAccessibilityDescriptor: String {
        let duration = UsageFormatting.windowName(minutes: window.windowMinutes)
        return effectiveScopeName.map { "\($0) · \(duration)" } ?? duration
    }

    private var accessibilityProviderName: String {
        guard let source = attribution?.displayName else { return provider.displayName }
        return "\(provider.displayName) · \(source)"
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

    private var fixedTint: Color? {
        switch pace.status {
        case .onTrack: return nil
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
        .usageDockAdaptiveForeground(.secondary, fixedColor: fixedTint)
        .accessibilityElement(children: .combine)
    }
}
