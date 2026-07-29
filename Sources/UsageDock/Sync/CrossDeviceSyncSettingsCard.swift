#if TOKENREMAIN_CLOUD_SYNC
import SwiftUI

struct CrossDeviceSyncSettingsCard: View {
    @ObservedObject private var sync = CrossDeviceSyncController.shared
    @State private var showsPreview = false
    @State private var confirmsDeletion = false
    @State private var confirmsSourceRemoval = false

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(
                    title: L10n.text("sync.card.title"),
                    subtitle: L10n.text("sync.card.subtitle")
                )

                Toggle(isOn: enabledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("sync.toggle.encrypt_title"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DashboardTheme.text)
                        Text(L10n.text("sync.toggle.encrypt_detail"))
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
                .tint(DashboardTheme.violet)

                Toggle(isOn: usageHistoryBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("sync.toggle.history_title"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DashboardTheme.text)
                        Text(L10n.text("sync.toggle.history_detail"))
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
                .tint(DashboardTheme.violet)
                .disabled(!sync.isEnabled)

                if sync.isEnabled {
                    LabeledContent(L10n.text("sync.health.icloud")) {
                        Label(iCloudHealthText, systemImage: iCloudHealthIcon)
                            .foregroundStyle(iCloudHealthColor)
                    }
                    LabeledContent(L10n.text("sync.health.key")) {
                        Label(syncKeyHealthText, systemImage: syncKeyHealthIcon)
                            .foregroundStyle(syncKeyHealthColor)
                    }
                    if let checkedAt = sync.lastAutomaticCheckAt {
                        LabeledContent(L10n.text("sync.health.last_check")) {
                            Text(checkedAt.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(DashboardTheme.secondaryText)
                        }
                    }
                }

                Label(statusText, systemImage: statusIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)

                if let sourceAnonymousID = sync.sourceAnonymousID {
                    LabeledContent(L10n.text("devices.this_mac")) {
                        Text("Mac · \(sourceAnonymousID)")
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                }

                DisclosureGroup(isExpanded: $showsPreview) {
                    VStack(alignment: .leading, spacing: 7) {
                        if sync.previewProviders.isEmpty {
                            Text(L10n.text("sync.preview.empty"))
                                .foregroundStyle(DashboardTheme.secondaryText)
                        } else {
                            ForEach(sync.previewProviders) { provider in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(provider.id)
                                        .foregroundStyle(DashboardTheme.text)
                                    Spacer()
                                    Text(windowSummary(provider.windows))
                                        .foregroundStyle(DashboardTheme.secondaryText)
                                }
                            }
                        }
                        if sync.syncUsageHistoryEnabled {
                            HStack {
                                Text(L10n.text("sync.preview.history_label"))
                                    .foregroundStyle(DashboardTheme.text)
                                Spacer()
                                Text(L10n.format("sync.preview.history_days", sync.previewHistoryDays))
                                    .foregroundStyle(DashboardTheme.secondaryText)
                            }
                        }
                        Text(L10n.text("sync.preview.whitelist_note"))
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 6)
                } label: {
                    Text(L10n.text("sync.preview.disclosure"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DashboardTheme.text)
                }

                Divider().overlay(DashboardTheme.border)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Spacer()
                        managementButtons
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        managementButtons
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .usageDockActionButtonStyle()

                Text(L10n.text("sync.footnote.encryption"))
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(L10n.text("sync.alert.delete_title"), isPresented: $confirmsDeletion) {
            Button(L10n.text("action.cancel"), role: .cancel) {}
            Button(L10n.text("sync.alert.delete_confirm"), role: .destructive) {
                Task { await sync.deleteCloudDataAndDisconnect() }
            }
        } message: {
            Text(L10n.text("sync.alert.delete_message"))
        }
        .alert(L10n.text("sync.alert.remove_source_title"), isPresented: $confirmsSourceRemoval) {
            Button(L10n.text("action.cancel"), role: .cancel) {}
            Button(L10n.text("sync.alert.remove_source_confirm"), role: .destructive) {
                Task { await sync.removeThisMacSourceAndDisconnect() }
            }
        } message: {
            Text(L10n.text("sync.alert.remove_source_message"))
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { sync.isEnabled }, set: sync.setEnabled)
    }

    @ViewBuilder
    private var managementButtons: some View {
        if case .failed = sync.state {
            Button(L10n.text("sync.action.recheck")) { sync.checkNow() }
                .disabled(!sync.isEnabled)
        }
        if sync.sourceAnonymousID != nil {
            Button(L10n.text("sync.action.remove_this_mac"), role: .destructive) {
                confirmsSourceRemoval = true
            }
        }
        Button(L10n.text("sync.action.delete_disconnect"), role: .destructive) {
            confirmsDeletion = true
        }
    }

    private var usageHistoryBinding: Binding<Bool> {
        Binding(get: { sync.syncUsageHistoryEnabled }, set: sync.setUsageHistoryEnabled)
    }

    private var statusText: String {
        switch sync.state {
        case .off: return L10n.text("sync.status.off")
        case .needsSignedCapabilities: return L10n.text("sync.status.needs_capabilities")
        case .waitingForMacData: return L10n.text("sync.status.waiting_for_mac_data")
        case .checkingICloud: return L10n.text("sync.status.checking_icloud")
        case .uploading: return L10n.text("sync.status.uploading")
        case .synced(let date):
            return L10n.format("sync.last_synced", date.formatted(date: .omitted, time: .shortened))
        case .failed(let failure): return failureText(failure)
        }
    }

    private var statusIcon: String {
        switch sync.state {
        case .synced: "checkmark.shield.fill"
        case .uploading, .checkingICloud: "arrow.triangle.2.circlepath.icloud"
        case .failed, .needsSignedCapabilities: "exclamationmark.triangle.fill"
        case .off, .waitingForMacData: "lock.icloud"
        }
    }

    private var statusColor: Color {
        switch sync.state {
        case .synced: DashboardTheme.success
        case .failed, .needsSignedCapabilities: DashboardTheme.warning
        default: DashboardTheme.secondaryText
        }
    }

    private var iCloudHealthText: String {
        switch sync.iCloudAvailable {
        case true: L10n.text("sync.health.available")
        case false: L10n.text("sync.health.unavailable")
        case nil: L10n.text("sync.health.checking")
        }
    }

    private var iCloudHealthIcon: String {
        switch sync.iCloudAvailable {
        case true: "checkmark.circle.fill"
        case false: "icloud.slash"
        case nil: "icloud"
        }
    }

    private var iCloudHealthColor: Color {
        switch sync.iCloudAvailable {
        case true: DashboardTheme.success
        case false: DashboardTheme.warning
        case nil: DashboardTheme.secondaryText
        }
    }

    private var syncKeyHealthText: String {
        switch sync.syncKeyAvailable {
        case true: L10n.text("sync.health.ready")
        case false: L10n.text("sync.health.unavailable")
        case nil: L10n.text("sync.health.checking")
        }
    }

    private var syncKeyHealthIcon: String {
        switch sync.syncKeyAvailable {
        case true: "key.fill"
        case false: "key.slash"
        case nil: "key.horizontal"
        }
    }

    private var syncKeyHealthColor: Color {
        switch sync.syncKeyAvailable {
        case true: DashboardTheme.success
        case false: DashboardTheme.warning
        case nil: DashboardTheme.secondaryText
        }
    }

    private func failureText(_ failure: CrossDeviceSyncController.Failure) -> String {
        switch failure {
        case .iCloudUnavailable: L10n.text("sync.failure.icloud_unavailable")
        case .keychainUnavailable: L10n.text("sync.failure.keychain_unavailable")
        case .networkUnavailable: L10n.text("sync.failure.network_unavailable")
        case .serviceUnavailable: L10n.text("sync.failure.service_unavailable")
        case .encryptionFailed: L10n.text("sync.failure.encryption_failed")
        case .unknown: L10n.text("sync.failure.unknown")
        }
    }

    private func windowSummary(_ windows: [CrossDeviceSyncController.PreviewProvider.Window]) -> String {
        windows.map { window in
            let value = String(format: "%.0f%%", window.usedPercent)
            return window.windowMinutes == 0
                ? value
                : L10n.format("sync.preview.window_minutes", value, window.windowMinutes)
        }.joined(separator: " · ")
    }
}
#endif
