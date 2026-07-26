import SwiftUI
import UniformTypeIdentifiers

/// Dashboard Limits: the authoritative view of every official quota window,
/// reusing the popover's `QuotaCard`. Pure live data. Providers that are not
/// connected yet render their onboarding hint inside the card instead of an
/// endless spinner — connecting is automatic (log into the tool) for every
/// provider except Z.ai, whose API key lives in the Data Sources section.
struct LimitsSection: View {
    let insights: UsageInsights
    var notices: [ProviderQuota.Provider: String] = [:]
    var serviceStatuses: [ProviderQuota.Provider: ProviderServiceStatus] = [:]
    @ObservedObject var tracked: TrackedProvidersStore = .shared
    @State private var draggingProvider: ProviderQuota.Provider?

    private func quota(for provider: ProviderQuota.Provider) -> ProviderQuota? {
        insights.quota(for: provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.limits.title,
                subtitle: DashboardSection.limits.subtitle,
                trailing: insights.lastUpdated.map { L10n.format("common.updated_at", $0.formatted(date: .omitted, time: .standard)) }
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14, alignment: .top)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(tracked.enabledOrdered, id: \.self) { provider in
                    QuotaCard(
                        provider: provider,
                        quota: quota(for: provider),
                        serviceStatus: serviceStatuses[provider],
                        notice: notices[provider],
                        draggingProvider: $draggingProvider
                    )
                        .frame(maxWidth: .infinity, alignment: .top)
                        // The invisible source card preserves a true grid gap
                        // while the full-card preview follows the pointer.
                        .opacity(draggingProvider == provider ? 0 : 1)
                        .animation(.easeOut(duration: 0.12), value: draggingProvider)
                        .onDrop(
                            of: [.plainText],
                            delegate: ProviderCardDropDelegate(
                                destination: provider,
                                tracked: tracked,
                                draggingProvider: $draggingProvider
                            )
                        )
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(.snappy) { tracked.setEnabled(provider, false) }
                            } label: {
                                Label(L10n.format("limits.stop_tracking_named", provider.displayName), systemImage: "minus.circle")
                            }
                        }
                }

                if !tracked.disabledOrdered.isEmpty {
                    AddProviderTile(tracked: tracked)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(title: L10n.text("limits.about_windows_title"))
                    Text(L10n.text("limits.about_windows_body"))
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("limits.manage_tracking_hint"))
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("limits.reset_time_note"))
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ProviderCardDropDelegate: DropDelegate {
    let destination: ProviderQuota.Provider
    let tracked: TrackedProvidersStore
    @Binding var draggingProvider: ProviderQuota.Provider?

    func dropEntered(info: DropInfo) {
        guard let draggingProvider, draggingProvider != destination else { return }
        withAnimation(.snappy(duration: 0.2)) {
            tracked.move(draggingProvider, to: destination)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProvider = nil
        return true
    }
}

/// 「添加应用」虚线卡片:列出未追踪的应用与它们的检测状态,
/// 点一下即加入追踪(与卡片右键"停止追踪"互为镜像)。
private struct AddProviderTile: View {
    @ObservedObject var tracked: TrackedProvidersStore

    private var detections: [TrackedProvidersStore.Detection] {
        TrackedProvidersStore.detections().filter { !tracked.isEnabled($0.provider) }
    }

    var body: some View {
        Menu {
            ForEach(detections) { detection in
                Button {
                    withAnimation(.snappy) { tracked.setEnabled(detection.provider, true) }
                } label: {
                    Label(
                        detection.installed
                            ? L10n.format("limits.provider_detected", detection.provider.displayName)
                            : L10n.format("limits.provider_not_detected", detection.provider.displayName),
                        systemImage: detection.installed ? "checkmark.circle" : "circle.dashed"
                    )
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.dashed")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DashboardTheme.secondaryText)
                Text(L10n.text("limits.add_app"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(L10n.text("limits.add_app_subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 132)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        DashboardTheme.border,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(L10n.text("limits.add_app_accessibility"))
    }
}
