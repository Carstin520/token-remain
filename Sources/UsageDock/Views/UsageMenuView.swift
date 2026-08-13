import AppKit
import SwiftUI

/// The menu-bar popover is a compact, user-arrangeable widget stack. The risk
/// summary stays fixed while every content card can be reordered or hidden.
struct UsageMenuView: View {
    private static let reorderCoordinateSpace = "tokenremain.popover.direct-reorder"

    @ObservedObject var store: UsageStore
    @ObservedObject var feedStore: AIFeedStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var layout: PopoverLayoutStore
    @ObservedObject var tracked: TrackedProvidersStore = .shared
    @ObservedObject var preferences: PreferencesStore = .shared
    /// Opens (and fronts) the Dashboard window on a given section.
    let onOpenDashboard: (DashboardSection) -> Void
    /// The macOS 26 menu-bar panel owns its AppKit window size explicitly.
    /// Other hosts keep this nil and retain their fixed window/popover size.
    var onResolvedHeightChange: ((CGFloat) -> Void)? = nil

    @State private var measuredHeight: CGFloat = 700
    @State private var reorderInteraction = DirectReorderInteraction<PopoverWidget>()
    @State private var isSettingsPresented = false
    @State private var footerHeight: CGFloat = 0

    private var insights: UsageInsights {
        UsageInsights(
            claude: nil,
            codex: nil,
            others: Array(store.quotas.values),
            daily: store.daily,
            history: store.history
        )
    }

    /// Cap the popover to the visible screen so long content scrolls instead of
    /// being clipped by the menu bar.
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 48
    }

    private var combinedError: String? {
        [store.errorMessage, launchAtLogin.errorMessage]
            .compactMap { $0 }
            .joined(separator: "\n")
            .nonEmpty
    }

    private var visibleWidgets: [PopoverWidget] {
        layout.visibleWidgets.filter(isTracked)
    }

    var body: some View {
        ScrollView {
            UsageDockGlassGroup(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    RiskStrip(insights: insights)

                    ForEach(visibleWidgets) { widget in
                        widgetView(widget)
                            .directReorder(
                                item: widget,
                                candidates: visibleWidgets,
                                coordinateSpace: Self.reorderCoordinateSpace,
                                interaction: reorderInteraction,
                                layout: .vertical(spacing: 12),
                                move: { source, target in
                                    layout.move(source, to: target)
                                }
                            )
                            // `zIndex` must live on the VStack's direct child.
                            // Keeping it only inside the shared modifier lets
                            // Liquid Glass preserve the original sibling order.
                            .zIndex(reorderInteraction.isDragging(widget) ? 10_000 : 0)
                    }

                    if let combinedError {
                        Label(combinedError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().usageDockPopoverSeparator().padding(.top, 1)

                    PopoverFooter(
                        launchAtLogin: launchAtLogin,
                        onOpenDashboard: onOpenDashboard,
                        isSettingsPresented: $isSettingsPresented
                    )
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        footerHeight = height
                    }
                }
                .padding(16)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PopoverHeightKey.self, value: proxy.size.height)
                    }
                )
            }
        }
        .coordinateSpace(name: Self.reorderCoordinateSpace)
        // Keep the captured reorder geometry stable for the lifetime of a
        // press. Interruption fallbacks in the shared interaction guarantee
        // this is re-enabled even if AppKit loses the normal gesture end.
        .scrollDisabled(reorderInteraction.isActive)
        .frame(width: 380)
        .frame(height: min(measuredHeight, maxHeight))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onResolvedHeightChange?(height)
        }
        // The settings editor floats over the whole popup, OUTSIDE the
        // GlassEffectContainer. Two reasons this is not laid out in flow:
        // inserting it resized the popup and re-laying the live glass
        // container recursed inside the system's glass transition machinery
        // until the stack guard killed the process (EXC_BAD_ACCESS in
        // DesignLibrary / glassTransitionState); and inside the container the
        // glass card surfaces composite above flat siblings, drawing over the
        // panel. Anchored to the popup's bottom, seated 10pt above the
        // footer's command row.
        .overlay(alignment: .bottom) {
            if isSettingsPresented {
                PopoverSettingsPanel(
                    launchAtLogin: launchAtLogin,
                    preferences: preferences,
                    onOpenDashboard: onOpenDashboard,
                    onClose: { isSettingsPresented = false }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, footerHeight + 16 + 10)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isSettingsPresented)
        .background {
            UsageDockCanvasBackground(
                inkOpacity: preferences.popoverBackgroundOpacity,
                glassStyle: preferences.popoverGlassStyle
            )
        }
        // The shell edge belongs to whatever hosts this stack: the menu-bar
        // panel draws its own rim because it has no system frame, while the
        // floating widget and the macOS 14/15 popover already have one.
        .environment(
            \.usageDockPopoverBackdropOpacity,
            preferences.popoverBackgroundOpacity
        )
        .environment(
            \.usageDockPopoverGlassStyle,
            preferences.popoverGlassStyle
        )
        .preferredColorScheme(.dark)
        .onPreferenceChange(PopoverHeightKey.self) { measuredHeight = $0 }
        .task {
            store.start()
            feedStore.start()
        }
    }

    @ViewBuilder
    private func widgetView(_ widget: PopoverWidget) -> some View {
        switch widget {
        case .localUsage:
            LocalUsageCard(
                insights: insights,
                localUsageStatus: store.localUsageStatus,
                isRefreshing: store.isCCUsageRefreshing,
                onRetry: {
                    Task { await store.refresh(forceCCUsage: true, forceClaude: false) }
                },
                layout: layout
            )
        case .aiFeed:
            AIFeedHotStoriesCard(
                posts: feedStore.topStories,
                isExpanded: layout.isExpanded(.aiFeed),
                layout: layout,
                onViewAll: { onOpenDashboard(.overview) }
            )
        default:
            // 其余挂件都是 provider 额度卡,provider 映射必然非空。
            let provider = widget.provider!
            PopoverQuotaWidget(
                provider: provider,
                quota: store.quotaValue(for: provider),
                serviceStatus: store.serviceStatuses[provider],
                notice: store.providerNotices[provider],
                layout: layout
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TokenRemainWordmark(size: 18, style: .monochrome)

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(updatedSubtitle(at: context.date))
                        .font(.system(size: 10))
                        .usageDockAdaptiveForeground(.muted)
                }
            }
            Spacer()
            addWidgetMenu
            refreshButton
        }
    }

    /// 未追踪的 provider 挂件既不显示,也不进 "+" 菜单;追踪管理在
    /// Dashboard「额度」页统一进行。
    private func isTracked(_ widget: PopoverWidget) -> Bool {
        widget.provider.map(tracked.isEnabled) ?? true
    }

    private var addWidgetMenu: some View {
        Menu {
            if layout.availableWidgets.filter(isTracked).isEmpty {
                Button(L10n.text("widget.all_visible")) {}
                    .disabled(true)
            } else {
                ForEach(layout.availableWidgets.filter(isTracked)) { widget in
                    Button {
                        withAnimation(.snappy) {
                            layout.show(widget)
                        }
                    } label: {
                        Label(L10n.format("widget.add_named", widget.title), systemImage: widget.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .usageDockAdaptiveForeground(.primary)
                .frame(width: 26, height: 26)
                // The glass surface supplies its own rim; a second palette-colored
                // circle on top of it was the button's share of the wireframe.
                .usageDockGlassSurface(
                    cornerRadius: 13,
                    interactive: true,
                    fallbackBackground: DashboardTheme.surface,
                    fallbackBorder: DashboardTheme.border
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 34)
        .usageDockAdaptiveTint(.primary)
        .help(L10n.text("action.add_widget"))
        .accessibilityLabel(L10n.text("action.add_widget"))
    }

    private func updatedSubtitle(at date: Date) -> String {
        if let updated = insights.lastUpdated {
            return UsageFormatting.freshnessDescription(since: updated, now: date)
        }
        return L10n.text("sync.loading")
    }

    private var refreshButton: some View {
        Button {
            Task { await store.refresh(forceCCUsage: true, forceClaude: true) }
        } label: {
            Group {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .usageDockAdaptiveForeground(.primary)
                }
            }
            .frame(width: 26, height: 26)
            // `.buttonStyle(.glass)` would pin this control to regular glass, so
            // the popup's two header buttons would sit side by side in different
            // materials and only one would follow the Clear/Frosted preference.
            .usageDockGlassSurface(
                cornerRadius: 13,
                interactive: true,
                fallbackBackground: DashboardTheme.surface,
                fallbackBorder: DashboardTheme.border
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 34, height: 34)
        .disabled(store.isRefreshing)
        .help(L10n.text("action.refresh_quota"))
        .accessibilityLabel(L10n.text("action.refresh_usage"))
    }
}

/// Reports the intrinsic content height so the popover can size to its content
/// yet cap at the screen height.
private struct PopoverHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
