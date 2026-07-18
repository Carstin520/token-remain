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
        UsageInsights(claude: store.claude, codex: store.codex, daily: store.daily)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 244)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 620)
        .background(DashboardTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(DashboardTheme.codex)
        .task { store.start() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandLockup
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

            List(selection: sidebarSelection) {
                ForEach(DashboardSection.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(DashboardSection.sections(in: group)) { section in
                            Label(section.title, systemImage: section.systemImage)
                                .font(.system(size: 12))
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            syncFooter
                .padding(14)
        }
        .background(DashboardTheme.canvas)
    }

    private var sidebarSelection: Binding<DashboardSection?> {
        Binding(
            get: { navigator.selection },
            set: { if let value = $0 { navigator.selection = value } }
        )
    }

    private var brandLockup: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [DashboardTheme.codex, DashboardTheme.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 27, height: 27)
                .overlay(
                    Text("U")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                )
            Text("UsageDock")
                .font(.system(size: 15, weight: .bold))
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
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("立即刷新所有数据源")
                .accessibilityLabel("刷新")
            }
            StatusDotLabel(color: syncColor, text: syncText, bold: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(DashboardTheme.border, lineWidth: 1)
        )
    }

    private var syncColor: Color {
        if store.errorMessage != nil { return DashboardTheme.warning }
        if insights.lastUpdated == nil { return DashboardTheme.mutedText }
        return DashboardTheme.success
    }

    private var syncText: String {
        if store.errorMessage != nil { return "部分数据源异常" }
        if insights.lastUpdated == nil { return "正在读取数据…" }
        return "全部数据源正常"
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            sectionContent
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DashboardTheme.canvas)
        .navigationTitle("UsageDock")
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch navigator.selection {
        case .overview:
            OverviewSection(insights: insights, errorMessage: store.errorMessage)
        case .aiFeed:
            AIFeedSection(store: feedStore)
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
