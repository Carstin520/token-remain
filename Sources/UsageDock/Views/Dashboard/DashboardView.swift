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
    @ObservedObject var visibility: DashboardVisibility
    @ObservedObject var tracked: TrackedProvidersStore = .shared
    @ObservedObject var preferences: PreferencesStore = .shared
    @ObservedObject private var appUpdater = AppUpdateController.shared
    @State private var limitsReorderInteraction = DirectReorderInteraction<ProviderQuota.Provider>()
#if TOKENREMAIN_CLOUD_SYNC
    @ObservedObject private var cloudSync = CrossDeviceSyncController.shared
#endif

    private var insights: UsageInsights {
        UsageInsights(
            claude: nil,
            codex: nil,
            others: Array(store.quotas.values),
            daily: store.daily,
            history: store.history,
            quotaUsageHistory: store.quotaUsageHistory
        )
    }

    var body: some View {
        dashboardWithSyncGuidance
            // The one place the Dashboard's background-lightness preference
            // enters the view tree. Everything below resolves `DashboardSurface`
            // tokens against it, so the whole window — chrome, cards, sheets and
            // the Settings page itself — moves together and updates live while
            // the slider is dragged. The menu-bar popup never sees this
            // environment and keeps the fixed dark palette it configures with
            // its own opacity slider.
            .dashboardSurfaces(lightness: preferences.dashboardBackgroundLightness)
            .alert(item: detectedProviderBinding) { detection in
                Alert(
                    title: Text(
                        L10n.format(
                            "provider.detect.prompt_title",
                            detection.provider.displayName
                        )
                    ),
                    message: Text(
                        L10n.format(
                            "provider.detect.prompt_message",
                            detection.provider.displayName
                        )
                    ),
                    primaryButton: .default(Text(L10n.text("provider.detect.connect"))) {
                        tracked.acceptNextDetectionSuggestion()
                        navigator.selection = .limits
                    },
                    secondaryButton: .cancel(Text(L10n.text("provider.detect.not_now"))) {
                        tracked.dismissNextDetectionSuggestion()
                    }
                )
            }
    }

    @ViewBuilder
    private var dashboardWithSyncGuidance: some View {
#if TOKENREMAIN_CLOUD_SYNC
        dashboardContent
            .alert(item: syncGuidanceBinding) { guidance in
                Alert(
                    title: Text(syncGuidanceTitle(guidance)),
                    message: Text(syncGuidanceMessage(guidance)),
                    primaryButton: .default(Text(L10n.text("sync.guidance.review"))) {
                        navigator.selection = .devices
                        cloudSync.dismissGuidance()
                    },
                    secondaryButton: .cancel(Text(L10n.text("sync.guidance.later"))) {
                        cloudSync.dismissGuidance()
                    }
                )
            }
#else
        dashboardContent
#endif
    }

    private var detectedProviderBinding: Binding<TrackedProvidersStore.Detection?> {
        Binding(
            get: { tracked.pendingDetectionSuggestions.first },
            // Alert 的两个按钮会明确消费队首；setter 保持无副作用，避免
            // SwiftUI 自动写 nil 时误删紧随其后的第二条检测建议。
            set: { _ in }
        )
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if tracked.hasCompletedOnboarding {
            dashboardBody
        } else {
            OnboardingView(
                tracked: tracked,
                robotAnimated: visibility.isVisible,
                onChooseClaudeCookie: {
                    ClaudeCookieGuideWindowController.shared.show(store: store, openingSite: true)
                }
            )
                .frame(minWidth: 920, minHeight: 620)
        }
    }

#if TOKENREMAIN_CLOUD_SYNC
    private var syncGuidanceBinding: Binding<CrossDeviceSyncController.Guidance?> {
        Binding(
            get: { cloudSync.guidance },
            set: { value in
                if value == nil {
                    cloudSync.dismissGuidance()
                }
            }
        )
    }

    private func syncGuidanceTitle(_ guidance: CrossDeviceSyncController.Guidance) -> String {
        switch guidance {
        case .checkICloud: L10n.text("sync.guidance.icloud_title")
        case .checkKeychain: L10n.text("sync.guidance.keychain_title")
        }
    }

    private func syncGuidanceMessage(_ guidance: CrossDeviceSyncController.Guidance) -> String {
        switch guidance {
        case .checkICloud: L10n.text("sync.guidance.icloud_message")
        case .checkKeychain: L10n.text("sync.guidance.keychain_message")
        }
    }
#endif

    private var dashboardBody: some View {
        NavigationSplitView {
            sidebar
                // Narrower than 1.4 (220) so the Overview's window table and its two
                // side cards fit side by side at the default 1180 pt window;
                // 204 still fits "Account Management" on one line.
                .navigationSplitViewColumnWidth(min: 204, ideal: 204, max: 244)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        // Remove the toolbar title text. The NSWindow keeps its `title` property
        // for Mission Control / the window switcher / accessibility; this only
        // drops the duplicated in-toolbar text, keeping the sidebar toggle intact.
        // `.toolbar(removing: .title)` needs macOS 15+; pre-15 relies on the
        // window's `titleVisibility = .hidden` set in DashboardWindowController.
        .modifier(HideToolbarTitle())
        .frame(minWidth: 920, minHeight: 620)
        .background { UsageDockCanvasBackground() }
        .preferredColorScheme(.dark)
        .tint(DashboardTheme.violet)
        .task {
            store.start()
            CurrencyStore.shared.refreshIfStale()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandMark
                .padding(.horizontal, Self.sidebarInset)
                .padding(.top, 18)
                .padding(.bottom, 12)

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
                                .foregroundStyle(DashboardTheme.secondaryText)
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

            // The status card spans the same width as the selection capsule;
            // its text lands on the shared 20 pt edge.
            sidebarFooter
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
        }
        .usageDockSidebarBackground()
    }

    /// Brand mark, group titles, icons and the footer share one left edge:
    /// the list's 10 pt inset plus each row's 10 pt padding.
    private static let sidebarInset: CGFloat = 20
    /// Every row is the same height whatever its icon or trailing count, and
    /// every icon sits in the same fixed column, so all labels start on one line.
    private static let sidebarRowHeight: CGFloat = 28
    private static let sidebarIconWidth: CGFloat = 18

    /// One sidebar row with an explicit violet selection capsule and white
    /// (HIG-style) selected-label text, replacing the system-blue highlight.
    private func sidebarRow(_ section: DashboardSection) -> some View {
        let isSelected = navigator.selection == section
        let count = section == .limits ? insights.projectedRunOuts().count : 0
        return Button {
            // Re-publishing the current page would rebuild it for nothing.
            if navigator.selection != section { navigator.selection = section }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .frame(width: Self.sidebarIconWidth, alignment: .center)
                    .accessibilityHidden(true)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    attentionCount(count, onSelection: isSelected)
                }
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : DashboardTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Self.sidebarRowHeight, maxHeight: Self.sidebarRowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? DashboardTheme.violet : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressRippleButtonStyle(cornerRadius: 7))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(count > 0 ? "\(count) · \(L10n.text("pace.ahead_warning"))" : "")
    }

    /// How many windows are projected to run out before reset — the queue
    /// the Limits page exists for. Hidden at zero.
    private func attentionCount(_ count: Int, onSelection: Bool) -> some View {
        Text("\(count)")
            .numericFont(11, .bold)
            .foregroundStyle(onSelection ? Color.white : DashboardTheme.warning)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                Capsule().fill(onSelection ? Color.white.opacity(0.22) : DashboardTheme.warning.opacity(0.16))
            )
            .help(L10n.text("pace.ahead_warning"))
    }

    private var brandMark: some View {
        HStack(spacing: 10) {
            TokenRemainFullBodyRobot(
                remainingPercent: store.aggregateRemainingPercent,
                size: 42,
                animated: visibility.isVisible
            )

            TokenRemainWordmark(size: 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var syncFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("sync.status"))
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
                .help(L10n.text("action.refresh_all_sources"))
                .accessibilityLabel(L10n.text("action.refresh"))
            }
            StatusDotLabel(color: syncColor, text: syncText, bold: true)
            if store.errorMessage == nil, !attentionProviders.isEmpty {
                Text(attentionProviders.map(\.displayName).joined(separator: L10n.text("common.list_separator")))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .lineLimit(2)
                    .padding(.leading, 14)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .usageDockGlassSurface(cornerRadius: 11)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let version = appUpdater.availableVersion {
                Button {
                    appUpdater.presentAvailableUpdate()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(L10n.format("update.available_format", version))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DashboardTheme.violet)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressRippleButtonStyle(cornerRadius: 9))
                .help(L10n.text("update.install_help"))
                .accessibilityLabel(L10n.format("update.available_accessibility", version))
            }
            syncFooter
        }
    }

    /// Sources with a provider notice or data older than two refresh
    /// cycles, named under the status line so the problem is visible
    /// without opening Limits.
    private var attentionProviders: [ProviderQuota.Provider] {
        QuotaWindowTable.attentionProviders(
            quotas: insights.quotas,
            notices: store.providerNotices,
            refreshInterval: preferences.refreshInterval
        )
    }

    private var syncColor: Color {
        if store.errorMessage != nil { return DashboardTheme.warning }
        if insights.lastUpdated == nil { return DashboardTheme.mutedText }
        if !attentionProviders.isEmpty { return DashboardTheme.warning }
        return DashboardTheme.success
    }

    private var syncText: String {
        if store.errorMessage != nil { return L10n.text("sync.partial_error") }
        if insights.lastUpdated == nil { return L10n.text("sync.loading") }
        if !attentionProviders.isEmpty { return L10n.text("sync.partial_error") }
        return L10n.text("sync.healthy")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if navigator.selection == .settings {
            SettingsSection(store: store, launchAtLogin: launchAtLogin)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { UsageDockCanvasBackground() }
        } else {
            MinimumSizeShield {
                ScrollView {
                    UsageDockGlassGroup(spacing: 16) {
                        sectionContent
                            .padding(28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .scrollDisabled(limitsReorderInteraction.isActive)
            }
            .background { UsageDockCanvasBackground() }
        }
        // The NSWindow keeps its title property (set in DashboardWindowController)
        // for Mission Control / the window switcher, while `titleVisibility =
        // .hidden` suppresses duplicate titlebar text.
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch navigator.selection {
        case .overview:
            OverviewSection(
                insights: insights,
                notices: store.providerNotices,
                subscriptionAccounts: store.subscriptionAccounts,
                localUsageStatus: store.localUsageStatus,
                isCCUsageRefreshing: store.isCCUsageRefreshing,
                onRetryCCUsage: {
                    Task { await store.refresh(forceCCUsage: true, forceClaude: false) }
                },
                feedStore: feedStore,
                errorMessage: store.errorMessage
            )
        case .aiFeed:
            AIFeedSection(store: feedStore)
        case .limits:
            LimitsSection(
                insights: insights,
                notices: store.providerNotices,
                serviceStatuses: store.serviceStatuses,
                store: store,
                reorderInteraction: limitsReorderInteraction
            )
        case .trends:
            TrendsSection(
                insights: insights,
                localUsageStatus: store.localUsageStatus,
                isCCUsageRefreshing: store.isCCUsageRefreshing,
                onRetryCCUsage: {
                    Task { await store.refresh(forceCCUsage: true, forceClaude: false) }
                },
                tracked: tracked,
                disabledLocalUsageSourceIDs: store.disabledLocalUsageSourceIDs,
                throughput: store.modelThroughput
            )
        case .devices:
            DevicesSection(insights: insights)
        case .accounts:
            AccountsSection(store: store, tracked: tracked) {
                navigator.selection = .dataSources
            }
        case .dataSources:
            DataSourcesSection(
                store: store,
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

/// Answers the split view's minimum-size query for the scrolling detail
/// without measuring the page. The column's hosting view asks for its
/// minimum size on every layout and constraint pass — each countdown tick,
/// press, ripple or data change — and the scroll view answered by laying
/// the whole page out at zero width, uncached: ~50 ms per pass on Overview
/// (`NSHostingView.minSize` dominated the profile). A scroll view's minimum
/// is zero anyway, and the window enforces its own minimum size.
struct MinimumSizeShield<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        MinimumSizeShieldLayout { content }
    }
}

struct MinimumSizeShieldLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if Self.isMinimumQuery(proposal) {
            return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        }
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    // No alignment guides pass through. The default answers an alignment
    // query by placing the child — at the zero size of a minimum query,
    // which made the scroll view measure the whole page after all.
    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    /// The minimum-size query proposes zero in a dimension; real layout
    /// always proposes the column's actual size.
    static func isMinimumQuery(_ proposal: ProposedViewSize) -> Bool {
        proposal.width == 0 || proposal.height == 0
    }
}
