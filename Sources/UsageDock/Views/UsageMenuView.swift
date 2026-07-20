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
    /// Opens (and fronts) the Dashboard window on a given section.
    let onOpenDashboard: (DashboardSection) -> Void

    @State private var measuredHeight: CGFloat = 700
    @State private var draggingWidget: PopoverWidget?

    private var insights: UsageInsights {
        UsageInsights(claude: store.claude, codex: store.codex, daily: store.daily)
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

                    ForEach(layout.visibleWidgets) { widget in
                        widgetView(widget)
                            .opacity(draggingWidget == widget ? 0.62 : 1)
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
        case .claude:
            PopoverQuotaWidget(
                provider: .claude,
                quota: store.claude,
                layout: layout,
                draggingWidget: $draggingWidget
            )
        case .codex:
            PopoverQuotaWidget(
                provider: .codex,
                quota: store.codex,
                layout: layout,
                draggingWidget: $draggingWidget
            )
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
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            TokenRemainLogo(remainingPercent: store.aggregateRemainingPercent)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text("Token Remain")
                    .wordmarkFont(19)
                    .foregroundStyle(DashboardTheme.text)
                Text(updatedSubtitle)
                    .numericFont(11)
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            Spacer()
            addWidgetMenu
            refreshButton
        }
    }

    private var addWidgetMenu: some View {
        Menu {
            if layout.availableWidgets.isEmpty {
                Button(L10n.text("widget.all_visible")) {}
                    .disabled(true)
            } else {
                ForEach(layout.availableWidgets) { widget in
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
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .background(DashboardTheme.surface2, in: Circle())
        .help(L10n.text("action.add_widget"))
        .accessibilityLabel(L10n.text("action.add_widget"))
    }

    private var updatedSubtitle: String {
        if let updated = insights.lastUpdated {
            return L10n.format(
                "usage.updated_local",
                updated.formatted(date: .omitted, time: .shortened)
            )
        }
        return L10n.text("usage.loading_local")
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
