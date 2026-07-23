import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The menu-bar popover is a compact, user-arrangeable widget stack. The risk
/// summary stays fixed while every content card can be reordered or hidden.
struct UsageMenuView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var feedStore: AIFeedStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var layout: PopoverLayoutStore
    @ObservedObject var tracked: TrackedProvidersStore = .shared
    /// Opens (and fronts) the Dashboard window on a given section.
    let onOpenDashboard: (DashboardSection) -> Void

    @State private var measuredHeight: CGFloat = 700
    @State private var draggingWidget: PopoverWidget?

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

    var body: some View {
        ScrollView {
            UsageDockGlassGroup(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    RiskStrip(insights: insights)

                    ForEach(layout.visibleWidgets.filter(isTracked)) { widget in
                        widgetView(widget)
                            // Keep the widget's layout slot but render it empty;
                            // the explicit drag preview carries the whole card.
                            .opacity(draggingWidget == widget ? 0 : 1)
                            .animation(.easeOut(duration: 0.12), value: draggingWidget)
                            .onDrop(
                                of: [.plainText],
                                delegate: PopoverWidgetDropDelegate(
                                    destination: widget,
                                    layout: layout,
                                    draggingWidget: $draggingWidget
                                )
                            )
                    }

                    if let combinedError {
                        Label(combinedError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(DashboardTheme.border).padding(.top, 1)

                    PopoverFooter(launchAtLogin: launchAtLogin, onOpenDashboard: onOpenDashboard)
                }
                .padding(16)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PopoverHeightKey.self, value: proxy.size.height)
                    }
                )
            }
        }
        .frame(width: 380)
        .frame(height: min(measuredHeight, maxHeight))
        .background { UsageDockCanvasBackground() }
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
                layout: layout,
                draggingWidget: $draggingWidget
            )
        case .aiFeed:
            AIFeedHotStoriesCard(
                posts: feedStore.topStories,
                isExpanded: layout.isExpanded(.aiFeed),
                layout: layout,
                draggingWidget: $draggingWidget,
                onViewAll: { onOpenDashboard(.overview) }
            )
        default:
            // 其余挂件都是 provider 额度卡,provider 映射必然非空。
            let provider = widget.provider!
            PopoverQuotaWidget(
                provider: provider,
                quota: store.quotaValue(for: provider),
                notice: store.providerNotices[provider],
                layout: layout,
                draggingWidget: $draggingWidget
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenRemain")
                    .wordmarkFont(18)
                    .foregroundStyle(DashboardTheme.text)

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(updatedSubtitle(at: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.mutedText)
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
                .foregroundStyle(DashboardTheme.text)
                .frame(width: 26, height: 26)
                .usageDockGlassSurface(
                    cornerRadius: 13,
                    interactive: true,
                    fallbackBackground: DashboardTheme.surface,
                    fallbackBorder: DashboardTheme.border
                )
                .overlay {
                    Circle()
                        .strokeBorder(DashboardTheme.border, lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 34)
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
            if store.isRefreshing {
                ProgressView().controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DashboardTheme.text)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(width: 34, height: 34)
        .usageDockRoundControlStyle()
        .buttonBorderShape(.circle)
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
