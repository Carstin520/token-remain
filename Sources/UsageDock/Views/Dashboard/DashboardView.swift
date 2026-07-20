import SwiftUI

/// Drives which Dashboard section is shown. Owned by the window controller so
/// the popover can open the Dashboard directly on a chosen section.
@MainActor
final class DashboardNavigator: ObservableObject {
    @Published var selection: DashboardSection

    init(selection: DashboardSection = .overview) {
        self.selection = selection
    }
}

/// The standalone Dashboard: a native macOS sidebar/detail split over the same
/// live `UsageStore`. Real data drives Overview / Limits / Data Sources /
/// Settings; Trends and Devices render honest empty states.
struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var feedStore: AIFeedStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var navigator: DashboardNavigator

    private var insights: UsageInsights {
        UsageInsights(
            claude: store.claude,
            codex: store.codex,
            daily: store.daily,
            history: store.history
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 244)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        // Remove the toolbar title text: the sidebar brand lockup is the only
        // visible "Token Remain". The NSWindow keeps its `title` property (for
        // Mission Control / the window switcher / accessibility); this only drops
        // the duplicated in-toolbar text, keeping the sidebar toggle intact.
        // `.toolbar(removing: .title)` needs macOS 15+; pre-15 relies on the
        // window's `titleVisibility = .hidden` set in DashboardWindowController.
        .modifier(HideToolbarTitle())
        .frame(minWidth: 920, minHeight: 620)
        .background { UsageDockCanvasBackground() }
        .preferredColorScheme(.dark)
        .tint(DashboardTheme.violet)
        .task { store.start() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandLockup
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

            // Custom nav list: SwiftUI `.tint` does not recolor the macOS
            // NSTableView sidebar selection (it follows the system accent), so
            // selection is rendered here as an explicit violet capsule to stay
            // on the pixel-tech brand.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(DashboardSection.Group.allCases) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(DashboardTheme.mutedText)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 3)
                            ForEach(DashboardSection.sections(in: group)) { section in
                                sidebarRow(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            syncFooter
                .padding(14)
        }
        .usageDockSidebarBackground()
    }

    /// One sidebar row with an explicit violet selection capsule and white
    /// (HIG-style) selected-label text, replacing the system-blue highlight.
    private func sidebarRow(_ section: DashboardSection) -> some View {
        let isSelected = navigator.selection == section
        return Button {
            navigator.selection = section
        } label: {
            Label(section.title, systemImage: section.systemImage)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : DashboardTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? DashboardTheme.violet : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var brandLockup: some View {
        HStack(spacing: 10) {
            TokenRemainLogo(remainingPercent: store.aggregateRemainingPercent)
                .frame(width: 32, height: 32)
            Text("Token Remain")
                .wordmarkFont(15)
                .foregroundStyle(DashboardTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    private var syncFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("同步状态")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.mutedText)
                Spacer()
                Button {
                    Task { await store.refresh(forceCCUsage: true, forceClaude: true) }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                }
                .usageDockRoundControlStyle()
                .buttonBorderShape(.circle)
                .disabled(store.isRefreshing)
                .help("立即刷新所有数据源")
                .accessibilityLabel("刷新")
            }
            StatusDotLabel(color: syncColor, text: syncText, bold: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .usageDockGlassSurface(cornerRadius: 11)
    }

    private var syncColor: Color {
        if store.errorMessage != nil { return DashboardTheme.warning }
        if insights.lastUpdated == nil { return DashboardTheme.mutedText }
        return DashboardTheme.success
    }

    private var syncText: String {
        if store.errorMessage != nil { return L10n.text("sync.partial_error") }
        if insights.lastUpdated == nil { return L10n.text("sync.loading") }
        return L10n.text("sync.healthy")
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            UsageDockGlassGroup(spacing: 16) {
                sectionContent
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background { UsageDockCanvasBackground() }
        // No `.navigationTitle` here: the sidebar brand lockup is the only
        // visible "Token Remain". The NSWindow keeps its title property (set in
        // DashboardWindowController) for Mission Control / the window switcher,
        // while `titleVisibility = .hidden` suppresses the duplicate titlebar text.
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch navigator.selection {
        case .overview:
            OverviewSection(
                insights: insights,
                feedStore: feedStore,
                errorMessage: store.errorMessage
            )
        case .limits:
            LimitsSection(insights: insights)
        case .trends:
            TrendsSection(insights: insights)
        case .devices:
            DevicesSection(insights: insights)
        case .dataSources:
            DataSourcesSection(
                insights: insights,
                feedStore: feedStore,
                errorMessage: store.errorMessage
            )
        case .settings:
            SettingsSection(store: store, launchAtLogin: launchAtLogin)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Drops the duplicated toolbar title on macOS 15+ (the user runs macOS 26);
/// pre-15 falls back to the window's hidden `titleVisibility`.
private struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
