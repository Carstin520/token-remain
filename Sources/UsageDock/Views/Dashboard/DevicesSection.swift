import Foundation
import SwiftUI

/// Dashboard Devices: live facts about the publishing Mac and its private
/// CloudKit delivery path. This intentionally reports sync endpoints rather
/// than inventing a device inventory CloudKit does not expose to the app.
struct DevicesSection: View {
    let insights: UsageInsights
#if TOKENREMAIN_CLOUD_SYNC
    @ObservedObject private var sync = CrossDeviceSyncController.shared
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.devices.title,
                subtitle: DashboardSection.devices.subtitle
            )

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: L10n.text("devices.this_mac"), subtitle: L10n.text("devices.this_mac_subtitle")) {
                        StatusDotLabel(color: DashboardTheme.success, text: L10n.text("devices.monitoring"), bold: true)
                    }
                    InfoRow(label: L10n.text("devices.device_name"), value: deviceName)
                    InfoRow(label: L10n.text("devices.os_version"), value: osVersion)
                    InfoRow(label: L10n.text("devices.active_sources"), value: activeSourcesText)
                    if let updated = insights.lastUpdated {
                        InfoRow(label: L10n.text("devices.last_updated"), value: updated.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
#if TOKENREMAIN_CLOUD_SYNC
                DashboardCard {
                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeader(title: L10n.text("sync.cloudkit_title"), subtitle: L10n.text("sync.cloudkit_subtitle")) {
                            StatusDotLabel(color: syncStatusColor, text: syncStatusText, bold: true)
                        }
                        InfoRow(label: L10n.text("sync.database_label"), value: L10n.text("sync.private_database"))
                        InfoRow(label: L10n.text("sync.publishing_sources"), value: L10n.format("sync.source_count", sync.previewProviders.count))
                        InfoRow(label: L10n.text("sync.change_upload"), value: L10n.text("sync.upload_delay"))
                        InfoRow(label: L10n.text("sync.keepalive"), value: L10n.text("sync.keepalive_interval"))
                        if let uploaded = sync.lastUploadedAt {
                            InfoRow(
                                label: L10n.text("sync.last_uploaded"),
                                value: uploaded.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                        Text(L10n.text("sync.privacy_note"))
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)

                DashboardCard {
                    VStack(alignment: .leading, spacing: 14) {
                        PanelHeader(title: L10n.text("sync.receivers_title"), subtitle: L10n.text("sync.receivers_subtitle"))
                        RoadmapList(items: [
                            L10n.text("sync.roadmap.iphone_poll"),
                            L10n.text("sync.roadmap.silent_push"),
                            L10n.text("sync.roadmap.widgets"),
                            L10n.text("sync.roadmap.no_login")
                        ])
                        Text(L10n.text("sync.background_note"))
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
#else
                DashboardCard {
                    EmptyStateView(
                        icon: "lock.icloud",
                        title: L10n.text("sync.entitlement_missing_title"),
                        message: L10n.text("sync.entitlement_missing_message")
                    )
                }
#endif
            }
        }
    }

    private var deviceName: String {
        Host.current().localizedName ?? L10n.text("devices.this_mac")
    }

    private var osVersion: String {
        "macOS " + ProcessInfo.processInfo.operatingSystemVersion.shortString
    }

    private var activeSourcesText: String {
        var sources = insights.quotas.map { $0.provider.displayName }
        if insights.daily != nil { sources.append("ccusage") }
        return sources.isEmpty ? L10n.text("common.none") : sources.joined(separator: " · ")
    }

#if TOKENREMAIN_CLOUD_SYNC
    private var syncStatusText: String {
        switch sync.state {
        case .off: return L10n.text("sync.state.off")
        case .needsSignedCapabilities: return L10n.text("sync.state.needs_capabilities")
        case .waitingForMacData: return L10n.text("sync.state.waiting_data")
        case .checkingICloud: return L10n.text("sync.state.checking_icloud")
        case .anotherMacIsPrimary: return L10n.text("sync.state.other_mac_primary")
        case .uploading: return L10n.text("sync.state.uploading")
        case .synced: return L10n.text("sync.state.synced")
        case .failed: return L10n.text("sync.state.failed")
        }
    }

    private var syncStatusColor: Color {
        switch sync.state {
        case .synced: return DashboardTheme.success
        case .failed, .needsSignedCapabilities, .anotherMacIsPrimary: return DashboardTheme.warning
        default: return DashboardTheme.secondaryText
        }
    }
#endif
}

private extension OperatingSystemVersion {
    var shortString: String {
        patchVersion == 0
            ? "\(majorVersion).\(minorVersion)"
            : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}
