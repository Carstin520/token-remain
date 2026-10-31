import SwiftUI

/// Full provider quota card: brand row + plan pill, then one row per official
/// window (remaining %, progress bar, reset label). Shown in the Dashboard's
/// Limits section. Renders a waiting state before data arrives.
struct QuotaCard: View {
    /// Floor for near-empty cards (loading, setup), so a card alone in its row
    /// still keeps the shared slot.
    static let minimumContentHeight: CGFloat = 224
    /// Every card shows its whole content up to this height — three or four
    /// windows with resets, pace, reset cards, balances and model rows all fit
    /// (DB-002). Only beyond it (several accounts, many pools) does the
    /// content scroll below the pinned provider header.
    static let maximumContentHeight: CGFloat = 520
    /// Reserve one shared title slot for every grid card so quota rows stay
    /// aligned even when a compact connection warning is present.
    private static let headerHeight: CGFloat = 26

    let provider: ProviderQuota.Provider
    let quota: ProviderQuota?
    var serviceStatus: ProviderServiceStatus?
    /// Provider 级状态说明(如 Cursor 登录过期的恢复提示)。
    var notice: String?
    /// Observe managed-account changes even when the system quota stays nil.
    /// The Dashboard owns this store; cards never create a collector.
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: PreferencesStore = .shared
    /// Observed so a plan chosen on the subscription card retitles the pill.
    @ObservedObject private var costStore = SubscriptionCostStore.shared

    /// Managed-account alerts are card-local: renaming and removal must not open
    /// another window or settings route.
    @State private var pendingRenameID: ProviderAccountID?
    @State private var pendingRenameText = ""
    @State private var pendingRemoveID: ProviderAccountID?
    /// Every provider presents its setup requirements before starting login or
    /// accepting a secret, so the compact plus button never triggers a surprise.
    @State private var isPresentingAccountSetup = false
    @State private var pendingCredentialUpdateID: ProviderAccountID?
    /// 内容的自然高度(与视口无关,所以切换滚动不会反过来改变测量)。
    /// 首帧为 0,按"装得下"处理,加载态不闪滚动条。以前按窗口数量分两档:
    /// 两条以内按内容撑高,三条起塞进 224pt 固定槽位内层滚动,于是
    /// Claude(含 Fable)、Antigravity(含 Others)被裁切而同一行的 Codex
    /// 撑高。现在所有卡片同一规则:装得下就完整显示,行高由网格统一。
    @State private var naturalContentHeight: CGFloat = 0

    static func contentScrolls(naturalContentHeight: CGFloat) -> Bool {
        naturalContentHeight > maximumContentHeight + 0.5
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
                if Self.contentScrolls(naturalContentHeight: naturalContentHeight) {
                    ScrollView(.vertical) {
                        contentStack
                    }
                    .frame(height: Self.maximumContentHeight)
                } else {
                    contentStack
                }
            }
            .frame(minHeight: Self.minimumContentHeight, alignment: .top)
            // The content always lays out at its natural height, whatever
            // height the grid offers, so the scroll measurement above never
            // sees the row stretch. The frame below then fills the row the
            // `QuotaGridLayout` offers, so cards in a row read as one band.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top)
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
                store.renameProviderAccount(id, to: pendingRenameText)
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
                store.removeProviderAccount(id)
                pendingRemoveID = nil
            }
        } message: { id in
            Text(L10n.format(removeMessageKey(for: id), accountName(for: id)))
        }
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 11) {
            quotaContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heightReader { naturalContentHeight = $0 })
    }

    /// 尺寸测量探针:铺在被测视图的 background 里,不参与命中与布局。
    private func heightReader(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, newValue in update(newValue) }
        }
    }

    /// The card's small print: freshness, then the data source its rows no
    /// longer repeat ("Updated just now · Claude Web").
    static func freshnessLine(_ freshness: String, source: QuotaAttribution?) -> String {
        guard let source else { return freshness }
        return "\(freshness) · \(source.displayName)"
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
        if supportsMultipleAccounts,
           store.isAddingProviderAccount(provider) {
            AccountAddProgressRow(
                credentialKind: multiAccountCapability?.credentialKind,
                deadline: store.accountLoginDeadlines[provider],
                onCancel: { store.cancelProviderAccountLogin(provider) }
            )
        } else if let message = store.accountManagementNotice(for: provider) {
            Label(message, systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(L10n.format("accounts.management_notice", message))
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
                remainingBalance: quota.primary.remainingBalance ?? quota.remainingBalance,
                vendorSummary: quota.modelVendorSummary(for: quota.primary)
            )
            if let secondary = quota.secondary {
                Divider().overlay(DashboardSurface.border)
                QuotaWindowRow(
                    window: secondary,
                    provider: provider,
                    attribution: quota.attribution,
                    vendorSummary: quota.modelVendorSummary(for: secondary)
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
                    scopeName: scoped.displayName,
                    vendorSummary: quota.modelVendorSummary(for: scoped.window, scopedName: scoped.displayName)
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
            if let models = quota.modelUsage, !models.isEmpty {
                Divider().overlay(DashboardSurface.border)
                ProviderModelUsageRow(models: models, period: quota.modelUsagePeriod)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let isStale = context.date.timeIntervalSince(quota.capturedAt) >= 600
                Label {
                    Text(Self.freshnessLine(
                        UsageFormatting.freshnessDescription(since: quota.capturedAt, now: context.date),
                        source: quota.attribution
                    ))
                    .numericFont(10)
                } icon: {
                    Image(systemName: isStale ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                }
                .font(.system(size: 10))
                .foregroundStyle(isStale ? DashboardTheme.warning : DashboardTheme.mutedText)
            }
            if let notice {
                noticeDetail(notice)
            }
        } else if let credentialConfiguration {
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
        } else if let notice {
            noticeDetail(notice)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("quota.loading_official"))
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }

    }

    /// The header pill only flags that data is not updating; the actual reason
    /// (not signed in, expired login, HTTP failure, timeout) is shown here in
    /// full, matching the popover, so recovery guidance is never tooltip-only.
    @ViewBuilder
    private func noticeDetail(_ notice: String) -> some View {
        Label(notice, systemImage: "moon.zzz.fill")
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        if store.keychainAuthorizationRequired.contains(provider) {
            KeychainAuthorizationButton(store: store, provider: provider)
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

            if let plan = planLabel, !plan.isEmpty {
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

    /// The tier the subscription card names for the shown account (or for
    /// all of them, when they agree); otherwise the source's own label in
    /// its catalog spelling. Claude Web reports no plan, so a tier chosen on
    /// the card is the only one the pill can show.
    private var planLabel: String? {
        let summary = SubscriptionCostSummary.make(
            accounts: store.subscriptionAccounts(for: provider),
            overrides: costStore.overrides,
            rates: nil
        )
        return summary.catalogPlanName(for: provider, account: selectedAccount?.id)
            ?? quota.flatMap { SubscriptionPlanCatalog.displayName(provider: provider, planName: $0.planName) }
    }

    // MARK: - Multi-account

    /// The backend decides which providers expose a safe credential boundary.
    /// Providers without one (currently OpenCode and Kiro) keep exactly their
    /// previous header and content, including the absence of an Add button.
    private var multiAccountCapability: ProviderMultiAccountCapability? {
        provider.multiAccountCapability
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
        guard supportsMultipleAccounts else { return [] }
        return store.accountSnapshots(for: provider)
    }

    private var accountSelection: ProviderAccountSelection {
        store.accountSelection(for: provider)
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

    private var combinedAccountQuota: CombinedAccountQuota? {
        guard showsAccountOverview,
              let group = try? CombinedAccountQuota.evaluate(accountSnapshots).get(),
              preferences.combinesAccounts(for: provider, group: group) else { return nil }
        return group
    }

    private func visibleCombinedWindows(_ group: CombinedAccountQuota) -> [CombinedAccountQuota.Window] {
        guard let first = accountSnapshots.first(where: { $0.profile.isEnabled && $0.quota != nil })?.quota else {
            return group.windows
        }
        let visibleScopes = Set(Self.scopedWindows(in: first, preferences: preferences).map { "scoped:\($0.scopeID)" })
        return group.windows.filter { !$0.id.hasPrefix("scoped:") || visibleScopes.contains($0.id) }
    }

    private func accountName(for id: ProviderAccountID) -> String {
        accountSnapshots.first { $0.id == id }?.profile.accountDisplayName
            ?? L10n.text("accounts.untitled")
    }

    @ViewBuilder
    private var accountControls: some View {
        if supportsMultipleAccounts {
            HStack(spacing: 5) {
                if accountSnapshots.count > 1 || accountSnapshots.contains(where: { !$0.profile.isSystem }) {
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
            ? L10n.format("accounts.chip_all", combinedAccountQuota?.accountCount ?? summary.accountCount)
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
        CombinedAccountControl(provider: provider, snapshots: accountSnapshots, preferences: preferences)
        if let group = combinedAccountQuota {
            CombinedAccountQuotaView(group: group, windows: visibleCombinedWindows(group), provider: provider)
            let summary = store.accountSummary(for: provider)
            if summary.lowAccountCount > 0 {
                Text(L10n.format("accounts.summary_low", summary.lowAccountCount))
                    .font(.system(size: 10.5)).foregroundStyle(DashboardTheme.warning)
            }
        } else {
            separateAccountOverview
        }
    }

    @ViewBuilder
    private var separateAccountOverview: some View {
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

extension ProviderAccountProfile {
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
                remainingBalance: summary.remainingBalance,
                remainingCredits: summary.window.remainingCredits
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
struct AccountAddProgressRow: View {
    let credentialKind: ProviderAccountCredentialKind?
    let deadline: Date?
    let onCancel: () -> Void

    private var messageKey: String {
        credentialKind == .keychainSecret || deadline == nil
            ? "accounts.adding_progress_credential"
            : "accounts.adding_progress"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(messageKey))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
                        Text(L10n.format("accounts.login_remaining", String(format: "%d:%02d", seconds / 60, seconds % 60)))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                }
            }
            if deadline != nil {
                Spacer(minLength: 4)
                Button(L10n.text("action.cancel"), action: onCancel)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
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

/// Prominent failure flag pinned beside the provider name. Keeping it in the
/// fixed header makes refresh failures visible even when the quota rows below
/// need to scroll. Notices cover every failure class (#92: an expired Cursor
/// login read as "not signed in"), so the label stays neutral and the card
/// body carries the specific reason.
private struct QuotaConnectionNotice: View {
    let message: String

    var body: some View {
        Label {
            Text(L10n.text("quota.refresh_failed_hint"))
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
        .accessibilityLabel("\(L10n.text("quota.refresh_failed_hint")), \(message)")
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

/// Models the provider's own billing API attributes to the current cycle,
/// largest token total first. Three lines cover the common case without an
/// inner scroll; the rest collapse into a count.
struct ProviderModelUsageRow: View {
    let models: [ProviderModelUsage]
    /// Nil is the current billing cycle; relays report a recent span instead.
    var period: ModelUsagePeriod? = nil

    static let visibleLimit = 3

    private var totalTokens: Int64 {
        models.reduce(0) { $0 + $1.totalTokens }
    }

    static func title(for period: ModelUsagePeriod?) -> String {
        switch period {
        case nil: L10n.text("quota.models_this_cycle")
        case .days(let days): L10n.format("quota.models_recent_days", days)
        case .recentRequests(let count): L10n.format("quota.models_recent_requests", count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.title(for: period))
                .font(.system(size: 12))
                .usageDockAdaptiveForeground(.secondary)
            ForEach(Array(models.prefix(Self.visibleLimit).enumerated()), id: \.offset) { _, model in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.model)
                        .font(.system(size: 10.5))
                        .usageDockAdaptiveForeground(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.model)
                    Spacer(minLength: 8)
                    Text(detailText(for: model))
                        .numericFont(10.5, .semibold)
                        .usageDockAdaptiveForeground(.primary)
                        .fixedSize()
                }
            }
            if models.count > Self.visibleLimit {
                Text(L10n.format("quota.models_more", models.count - Self.visibleLimit))
                    .font(.system(size: 10))
                    .usageDockAdaptiveForeground(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detailText(for model: ProviderModelUsage) -> String {
        var parts = [UsageFormatting.compactNumber(model.totalTokens)]
        if totalTokens > 0 {
            parts.append(UsageFormatting.percent(Double(model.totalTokens) / Double(totalTokens) * 100))
        }
        if let cents = model.costCents, cents > 0 {
            parts.append(UsageFormatting.compactUSD(cents / 100))
        }
        return parts.joined(separator: " · ")
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
    /// Most-used model's local output speed, shown at the end of the reset
    /// line. Callers pass it to one row per provider only.
    var modelSpeed: ModelSpeedSummary? = nil
    /// Vendor logos for the models behind this row, after its name. A summary
    /// label ("Others") replaces the pool name, so callers never pass one
    /// when an account name labels the row.
    var vendorSummary: ModelVendorSummary? = nil
    @Environment(\.quotaDetailFontSize) private var detailFontSize

    /// Scoped rows are named by their call site; a general window can also
    /// name itself when it represents one pool of a split cycle (Cursor).
    private var effectiveScopeName: String? {
        scopeName ?? window.poolName
    }

    private var displayedVendorSummary: ModelVendorSummary? {
        guard let vendorSummary, !vendorSummary.marks.isEmpty else { return nil }
        return vendorSummary
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
                    if let summary = displayedVendorSummary {
                        let parts = Self.vendorTitleParts(
                            windowMinutes: window.windowMinutes,
                            name: summary.label ?? effectiveScopeName
                        )
                        HStack(alignment: .center, spacing: 5) {
                            Text(verbatim: parts.leading)
                                .font(.system(size: 13))
                                .usageDockAdaptiveForeground(.secondary)
                            ModelVendorMarkStrip(marks: summary.marks)
                            if let trailing = parts.trailing {
                                Text(verbatim: trailing)
                                    .font(.system(size: 13))
                                    .usageDockAdaptiveForeground(.secondary)
                            }
                        }
                    } else {
                        Text(windowTitle)
                            .font(.system(size: 13))
                            .usageDockAdaptiveForeground(.secondary)
                    }
                    Spacer()
                    if let pace = UsagePace(window: window, now: context.date),
                       pace.showsRemainingWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DashboardTheme.danger)
                            .help(L10n.text("pace.ahead_warning"))
                            .accessibilityLabel(L10n.text("pace.ahead_warning"))
                    }
                    RollingText(remainingText)
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
                            .font(.system(size: detailFontSize - 1))
                        if let resetsAt = window.resetsAt {
                            QuotaResetLabel(resetsAt: resetsAt, referenceDate: context.date)
                                .layoutPriority(1)
                        } else {
                            Text(L10n.text("quota.reset_pending"))
                                .layoutPriority(1)
                        }
                        if let modelSpeed {
                            Spacer(minLength: 8)
                            ModelSpeedLabel(speed: modelSpeed)
                        }
                    }
                    .font(.system(size: detailFontSize))
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
                remainingBalance: remainingBalance ?? window.remainingBalance,
                remainingCredits: window.remainingCredits
            )
        )
    }

    static func remainingValueText(
        remainingPercent: Double,
        remainingBalance: QuotaBalance?,
        remainingCredits: Double? = nil
    ) -> String {
        if let credits = remainingCredits, credits.isFinite, credits >= 0 {
            return L10n.format("alibaba.credits", credits)
        }
        return remainingBalance?.displayText ?? UsageFormatting.percent(remainingPercent)
    }

    private var windowTitle: String {
        Self.displayTitle(windowMinutes: window.windowMinutes, scopeName: effectiveScopeName)
    }

    /// The pool's name, if any, then just the length, spelled out ("5 hours",
    /// "7 days") now that the row has the room. The data source ("Claude Web", a billing API) is
    /// not part of a row: repeated on every bar it is noise, so the Dashboard
    /// names it once in small print and the menu-bar panel leaves it out.
    static func displayTitle(windowMinutes: Int, scopeName: String?) -> String {
        let duration = UsageFormatting.windowFullName(minutes: windowMinutes)
        return scopeName.map { "\($0) · \(duration)" } ?? duration
    }

    /// Title around the vendor logos: `Others [logos] · 31 d` for a named
    /// pool, `Total [logos]` for an unnamed account window.
    static func vendorTitleParts(
        windowMinutes: Int,
        name: String?
    ) -> (leading: String, trailing: String?) {
        let duration = UsageFormatting.windowFullName(minutes: windowMinutes)
        guard let name else { return (duration, nil) }
        return (name, "· \(duration)")
    }

    private var windowAccessibilityDescriptor: String {
        let duration = UsageFormatting.windowName(minutes: window.windowMinutes)
        var scope = effectiveScopeName
        if let summary = displayedVendorSummary {
            let vendors = summary.marks.prefix(ModelVendorMark.limit).map(\.vendor.displayName).joined(separator: ", ")
            let name: String? = summary.label ?? scope
            scope = name.map { "\($0) (\(vendors))" } ?? vendors
        }
        return scope.map { "\($0) · \(duration)" } ?? duration
    }

    private var accessibilityProviderName: String {
        guard let source = attribution?.displayName else { return provider.displayName }
        return "\(provider.displayName) · \(source)"
    }
}

/// 重置时间标签。距重置不足一小时才以秒级滚动倒计时;此时它是整个
/// 卡片里唯一按 1 秒刷新的叶子视图,重排被限制在这一小段文本内。
/// 一小时以上按分钟粒度显示,由外层 60 秒时间线驱动即可。
/// `gpt-6-astra · ≈26 tok/s`. The model name gives way first when space is
/// tight; the speed itself never truncates.
private struct ModelSpeedLabel: View {
    let speed: ModelSpeedSummary
    @Environment(\.quotaDetailFontSize) private var fontSize

    var body: some View {
        let help = L10n.format("quota.model_speed_help", speed.displayName, ModelSpeedSummary.windowDays)
        HStack(spacing: 4) {
            Text(speed.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·")
            Text(L10n.format("trends.model_tps_format", TrendModelBreakdownPanel.speedLabel(speed.tokensPerSecond)))
                .numericFont(fontSize, .medium)
                .usageDockAdaptiveForeground(.primary)
                .fixedSize()
        }
        .font(.system(size: fontSize))
        .usageDockAdaptiveForeground(.secondary)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .accessibilityValue(L10n.format("trends.model_tps_format", TrendModelBreakdownPanel.speedLabel(speed.tokensPerSecond)))
    }
}

private struct QuotaResetLabel: View {
    let resetsAt: Date
    /// 外层 60 秒时间线的当前时刻,同时决定秒级/分钟级两种模式的切换。
    let referenceDate: Date
    @Environment(\.quotaDetailFontSize) private var fontSize

    var body: some View {
        if UsageFormatting.showsLiveSecondCountdown(to: resetsAt, now: referenceDate) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(UsageFormatting.resetDescription(to: resetsAt, now: context.date))
                    .numericFont(fontSize)
            }
        } else {
            Text(UsageFormatting.resetDescription(to: resetsAt, now: referenceDate))
                .numericFont(fontSize)
        }
    }
}

private struct QuotaPaceRow: View {
    let pace: UsagePace
    let now: Date
    @Environment(\.quotaDetailFontSize) private var fontSize

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
        if pace.isExhausted {
            return L10n.text("pace.exhausted")
        }
        guard let runOutAt = pace.estimatedRunOutAt else { return L10n.text("pace.projected_early") }
        return L10n.format("pace.projected_in", UsageFormatting.durationUntil(runOutAt, now: now))
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: pace.willLastUntilReset ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: fontSize - 1))
            Text(paceLabel)
                .numericFont(fontSize, .medium)
            Spacer(minLength: 8)
            Text(outcomeLabel)
                .numericFont(fontSize)
        }
        .font(.system(size: fontSize))
        .usageDockAdaptiveForeground(.secondary, fixedColor: fixedTint)
        .accessibilityElement(children: .combine)
    }
}

/// Size of the reset, pace and model-speed lines under a quota window. The
/// Dashboard keeps 10 pt; the menu-bar popup raises them to 11 pt because
/// they sit on glass there, where 10 pt grey was hard to read.
private struct QuotaDetailFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 10
}

extension EnvironmentValues {
    var quotaDetailFontSize: CGFloat {
        get { self[QuotaDetailFontSizeKey.self] }
        set { self[QuotaDetailFontSizeKey.self] = newValue }
    }
}
