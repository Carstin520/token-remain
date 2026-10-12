import SwiftUI

/// Management stays reachable independently of quota availability, account
/// selection, and monitoring. The Dashboard owns the only scroll view.
struct AccountsSection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var tracked: TrackedProvidersStore
    let openDataSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.accounts.title,
                subtitle: DashboardSection.accounts.subtitle
            )
            // Applies to every app's switch alike, so it is said once here
            // rather than repeated in each card.
            Text(L10n.text("accounts.management.monitoring_note"))
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(tracked.order, id: \.self) { provider in
                ProviderAccountManagementCard(
                    provider: provider,
                    store: store,
                    tracked: tracked,
                    openDataSources: openDataSources
                )
            }
        }
    }
}

private struct ProviderAccountManagementCard: View {
    let provider: ProviderQuota.Provider
    @ObservedObject var store: UsageStore
    @ObservedObject var tracked: TrackedProvidersStore
    let openDataSources: () -> Void
    @State private var pendingRemoval: ProviderAccountProfile?
    @State private var pendingRename: ProviderAccountProfile?
    @State private var renamedText = ""
    @State private var editingProfile: ProviderAccountProfile?
    @State private var isPresentingSetup = false

    private var isMonitoring: Bool { tracked.isEnabled(provider) }

    // Do not use quota-card snapshots here: they intentionally suppress empty
    // system accounts. Management must also retain paused and unavailable rows.
    private var profiles: [ProviderAccountProfile] {
        store.providerAccountProfiles.filter { $0.provider == provider }
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 12)

                CombinedAccountControl(provider: provider, snapshots: store.accountSnapshots(for: provider)) {
                    store.setAccountSelection(.all, for: provider)
                }

                if profiles.isEmpty {
                    rowDivider
                    Text(L10n.text("accounts.management.single_source"))
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(profiles) { profile in
                        rowDivider
                        accountRow(profile)
                    }
                }

                rowDivider
                setupActions

                if store.isAddingProviderAccount(provider) {
                    AccountAddProgressRow(
                        credentialKind: provider.multiAccountCapability?.credentialKind,
                        deadline: store.accountLoginDeadlines[provider],
                        onCancel: { store.cancelProviderAccountLogin(provider) }
                    )
                    .padding(.top, 10)
                }
                if let notice = store.accountManagementNotice(for: provider) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
        }
        .alert(
            L10n.text("accounts.remove_title"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { profile in
            Button(L10n.text("action.cancel"), role: .cancel) { pendingRemoval = nil }
            Button(L10n.text("accounts.remove_confirm"), role: .destructive) {
                store.removeProviderAccount(profile.id)
                pendingRemoval = nil
            }
        } message: { profile in
            Text(L10n.format(
                profile.credentialKind == .keychainSecret
                    ? "accounts.remove_message_credential" : "accounts.remove_message",
                profile.accountDisplayName
            ))
        }
        .alert(
            L10n.text("accounts.rename_title"),
            isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } }
            ),
            presenting: pendingRename
        ) { profile in
            TextField(L10n.text("accounts.rename_placeholder"), text: $renamedText)
            Button(L10n.text("action.cancel"), role: .cancel) { pendingRename = nil }
            Button(L10n.text("action.save")) {
                store.renameProviderAccount(profile.id, to: renamedText)
                pendingRename = nil
            }
            .disabled(renamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || renamedText.trimmingCharacters(in: .whitespacesAndNewlines).count > 64)
        } message: { _ in
            Text(L10n.text("accounts.rename_message"))
        }
    }

    /// Same anatomy as the other Dashboard panels: identity on the left, the
    /// one panel-wide control on the right. Monitoring is an on/off state, so it
    /// is a switch rather than a button whose title flips.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            BrandIcon(provider: provider)
                .foregroundStyle(DashboardTheme.text)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                statusLabel(
                    L10n.text(isMonitoring
                        ? "accounts.management.monitoring" : "accounts.management.stopped"),
                    color: isMonitoring ? DashboardTheme.success : DashboardTheme.mutedText
                )
            }
            Spacer(minLength: 12)
            Toggle(provider.displayName, isOn: Binding(
                get: { isMonitoring },
                set: { tracked.setEnabled(provider, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(DashboardTheme.violet)
            .help(L10n.text(isMonitoring
                ? "accounts.management.stop" : "accounts.management.start"))
            .accessibilityHint(L10n.format(isMonitoring
                ? "accounts.management.stop_named" : "accounts.management.start_named", provider.displayName))
        }
    }

    /// Status is always a glyph plus words, never color alone.
    private func statusLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private var rowDivider: some View {
        Divider().overlay(DashboardSurface.border).padding(.vertical, 12)
    }

    /// One line per account: who it is and its state on the left; the enable
    /// switch and a menu for the occasional actions on the right, so the list
    /// reads as a list instead of a wall of buttons.
    private func accountRow(_ profile: ProviderAccountProfile) -> some View {
        let isLive = isMonitoring && (profile.isSystem || profile.isEnabled)
        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(isLive ? DashboardTheme.success : DashboardTheme.mutedText)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.accountDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text(profile.isSystem
                    ? "accounts.management.system_note"
                    : (profile.isEnabled ? "accounts.management.active" : "accounts.management.paused")))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !profile.isSystem {
                Toggle(profile.accountDisplayName, isOn: Binding(
                    get: { profile.isEnabled },
                    set: { setEnabled($0, profile) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DashboardTheme.violet)
                .help(L10n.text(profile.isEnabled ? "accounts.disable" : "accounts.enable"))

                accountMenu(profile)
            }
        }
    }

    private func setEnabled(_ enabled: Bool, _ profile: ProviderAccountProfile) {
        if !enabled, store.accountSelection(for: provider) == .account(profile.id) {
            store.setAccountSelection(.all, for: provider)
        }
        store.setProviderAccountEnabled(enabled, id: profile.id)
    }

    private func accountMenu(_ profile: ProviderAccountProfile) -> some View {
        Menu {
            Button(L10n.text("accounts.rename")) {
                renamedText = profile.accountDisplayName
                pendingRename = profile
            }
            if profile.credentialKind == .keychainSecret {
                Button(L10n.text("accounts.update_credential")) {
                    editingProfile = profile
                    isPresentingSetup = true
                }
                .disabled(!isMonitoring || store.isAddingProviderAccount(provider))
            }
            Divider()
            Button(L10n.text("accounts.remove"), role: .destructive) {
                pendingRemoval = profile
            }
            .accessibilityLabel(L10n.format("accounts.management.remove_named", profile.accountDisplayName))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DashboardTheme.secondaryText)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.format("accounts.management.more_named", profile.accountDisplayName))
    }

    private var setupActions: some View {
        HStack(spacing: 12) {
            if provider.multiAccountCapability != nil {
                Button {
                    editingProfile = nil
                    isPresentingSetup = true
                } label: {
                    Label(L10n.text("accounts.add"), systemImage: "plus")
                }
                .usageDockActionButtonStyle()
                .disabled(!isMonitoring || store.isAddingProviderAccount(provider))
            }
            Spacer(minLength: 0)
            Button(action: openDataSources) {
                Label(L10n.text("nav.data_sources"), systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .popover(isPresented: $isPresentingSetup) {
            if provider.multiAccountCapability?.credentialKind == .isolatedCLI {
                AddCLIProviderAccountSheet(store: store, provider: provider, isPresented: $isPresentingSetup)
            } else if let hint = ProviderAccountCredentialHint.resolve(for: provider) {
                AddProviderAccountSheet(
                    store: store, provider: provider, hint: hint,
                    editingProfile: editingProfile, isPresented: $isPresentingSetup
                )
            }
        }
        .onChange(of: isPresentingSetup) { _, presented in
            if !presented { editingProfile = nil }
        }
    }
}
