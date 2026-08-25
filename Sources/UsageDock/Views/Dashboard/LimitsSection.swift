import SwiftUI

/// Dashboard Limits: the authoritative view of every official quota window,
/// reusing the popover's `QuotaCard`. Pure live data. Providers that are not
/// connected yet render their onboarding hint inside the card instead of an
/// endless spinner. Providers that require a pasted API key or cookie expose
/// that setup directly in the empty quota card.
struct LimitsSection: View {
    private static let reorderCoordinateSpace = "tokenremain.dashboard.limits.direct-reorder"

    let insights: UsageInsights
    var notices: [ProviderQuota.Provider: String] = [:]
    var serviceStatuses: [ProviderQuota.Provider: ProviderServiceStatus] = [:]
    @ObservedObject var store: UsageStore
    @ObservedObject var tracked: TrackedProvidersStore = .shared
    let reorderInteraction: DirectReorderInteraction<ProviderQuota.Provider>

    /// Multi-account providers read the store's selection-aware projection;
    /// single-account providers keep using the original insights snapshot.
    private func quota(for provider: ProviderQuota.Provider) -> ProviderQuota? {
        guard provider.multiAccountCapability != nil else { return insights.quota(for: provider) }
        return store.displayedQuota(for: provider)
    }

    private func notice(for provider: ProviderQuota.Provider) -> String? {
        guard provider.multiAccountCapability != nil else { return notices[provider] }
        return store.displayedNotice(for: provider) ?? notices[provider]
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
                        notice: notice(for: provider),
                        store: store
                    )
                        .frame(maxWidth: .infinity, alignment: .top)
                        .directReorder(
                            item: provider,
                            candidates: tracked.enabledOrdered,
                            coordinateSpace: Self.reorderCoordinateSpace,
                            interaction: reorderInteraction,
                            layout: .grid(spacing: 14),
                            move: { source, target in
                                tracked.move(source, to: target)
                            }
                        )
                        .help(L10n.text("quota.drag_help"))
                        .accessibilityHint(L10n.text("quota.drag_accessibility"))
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(.snappy) { tracked.setEnabled(provider, false) }
                            } label: {
                                Label(L10n.format("limits.stop_tracking_named", provider.displayName), systemImage: "minus.circle")
                            }
                        }
                        // Apply the stacking trait after help/context-menu
                        // wrappers so the lifted card is the grid's top sibling
                        // and visibly covers every card it crosses.
                        .zIndex(reorderInteraction.isDragging(provider) ? 10_000 : 0)
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
        .coordinateSpace(name: Self.reorderCoordinateSpace)
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
                        DashboardSurface.border,
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
