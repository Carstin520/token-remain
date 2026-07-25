import SwiftUI
import TokenRemainKit

struct SettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                // Identity layer only — the controls below stay native (body layer).
                CyberPageHeader(title: TRL10n.t("tab.settings"))
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                Form {
                    sourceSection($model)
                    liveActivitySection
                    devicesSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .background(TRTheme.ink)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - 数据源

    private func sourceSection(_ model: Bindable<AppModel>) -> some View {
        Section {
            LabeledContent(TRL10n.t("settings.origin.row")) {
                Text(originStatus)
                    .foregroundStyle(TRTheme.textDim)
            }
            Toggle(
                TRL10n.t("overview.feed.title"),
                isOn: Binding(
                    get: { self.model.broadcastNotificationsEnabled },
                    set: { enabled in
                        Task { await self.model.setBroadcastNotificationsEnabled(enabled) }
                    }
                )
            )
            .tint(TRTheme.indigo)
            .accessibilityIdentifier("tr.settings.broadcastNotificationsToggle")
            Toggle(
                TRL10n.t("settings.macsync.toggle"),
                isOn: Binding(
                    get: { self.model.isMacSyncEnabled },
                    set: { self.model.setMacSyncEnabled($0) }
                )
            )
            .tint(TRTheme.indigo)
            .accessibilityIdentifier("tr.settings.macSyncToggle")
            if self.model.isMacSyncEnabled {
                NavigationLink {
                    syncDetailsPage
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TRL10n.t("settings.sync.details"))
                            Text(mobileSyncStatus)
                                .font(.caption)
                                .foregroundStyle(syncStatusColor)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: syncStatusIcon)
                            .foregroundStyle(syncStatusColor)
                    }
                }
                .accessibilityIdentifier("tr.settings.syncDetails")

                if case .sourceChangeRequiresConfirmation = self.model.mobileSyncState {
                    Button(TRL10n.t("settings.macsync.confirm")) {
                        self.model.acceptPendingMacSource()
                    }
                    .tint(TRTheme.indigo)
                } else if case .failed = self.model.mobileSyncState {
                    Button(TRL10n.t("settings.macsync.retry")) {
                        Task { await self.model.pullMacSync() }
                    }
                    .disabled(self.model.mobileSyncState == .pulling)
                }
            }
            Toggle(TRL10n.t("settings.demo.toggle"), isOn: model.isDemoEnabled)
                .tint(TRTheme.indigo)
                .accessibilityIdentifier("tr.settings.demoToggle")
            if self.model.isDemoEnabled {
                Picker(TRL10n.t("settings.scenario"), selection: model.demoScenario) {
                    ForEach(DemoScenario.allCases) { scenario in
                        Text(scenario.displayName).tag(scenario)
                    }
                }
                .accessibilityIdentifier("tr.settings.scenarioPicker")
            }
        } header: {
            Text(TRL10n.t("settings.section.source"))
        }
    }

    private var syncDetailsPage: some View {
        Form {
            Section(TRL10n.t("settings.sync.section.health")) {
                LabeledContent(TRL10n.t("settings.sync.automatic")) {
                    Label(
                        TRL10n.t("settings.sync.automatic_on"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(TRTheme.success)
                }
                Text(TRL10n.t("settings.sync.automatic_detail"))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textDim)
                LabeledContent(TRL10n.t("settings.sync.health.icloud")) {
                    Label(iCloudHealthText, systemImage: iCloudHealthIcon)
                        .foregroundStyle(iCloudHealthColor)
                }
                .accessibilityIdentifier("tr.settings.sync.health.icloud")
                LabeledContent(TRL10n.t("settings.sync.health.key")) {
                    Label(syncKeyHealthText, systemImage: syncKeyHealthIcon)
                        .foregroundStyle(syncKeyHealthColor)
                }
                LabeledContent(TRL10n.t("settings.sync.health.snapshot")) {
                    Label(macSnapshotHealthText, systemImage: macSnapshotHealthIcon)
                        .foregroundStyle(macSnapshotHealthColor)
                }
                Text(mobileSyncStatus)
                    .font(.footnote)
                    .foregroundStyle(syncStatusColor)

                if case .sourceChangeRequiresConfirmation = model.mobileSyncState {
                    Button(TRL10n.t("settings.macsync.confirm")) {
                        model.acceptPendingMacSource()
                    }
                    .tint(TRTheme.indigo)
                } else if case .failed = model.mobileSyncState {
                    Button(TRL10n.t("settings.macsync.retry")) {
                        Task { await model.pullMacSync() }
                    }
                    .disabled(model.mobileSyncState == .pulling)
                }
            }

            Section(TRL10n.t("settings.sync.section.activity")) {
                if let checkedAt = model.lastAutomaticSyncCheckAt {
                    LabeledContent(TRL10n.t("settings.sync.last_check")) {
                        Text(detailTime(checkedAt))
                            .foregroundStyle(TRTheme.textDim)
                    }
                }
                if let timing = model.latestSyncTiming {
                    LabeledContent(TRL10n.t("settings.sync.provider_captured")) {
                        Text(detailTime(timing.providerCapturedAt))
                            .foregroundStyle(TRTheme.textDim)
                    }
                    LabeledContent(TRL10n.t("settings.sync.phone_rendered")) {
                        Text(detailTime(timing.phoneRenderedAt))
                            .foregroundStyle(TRTheme.textDim)
                    }
                }
                if let summary = model.syncLatencySummary {
                    Text(TRL10n.f(
                        "settings.sync.latency",
                        summary.p50Seconds,
                        summary.p95Seconds,
                        summary.maximumSeconds,
                        summary.sampleCount
                    ))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textDim)
                }
                if model.lastAutomaticSyncCheckAt == nil,
                   model.latestSyncTiming == nil,
                   model.syncLatencySummary == nil {
                    Text(TRL10n.t("settings.sync.health.pending"))
                        .foregroundStyle(TRTheme.textDim)
                }
            }

            Section(TRL10n.t("settings.section.about")) {
                Text(TRL10n.t("settings.demo.footer"))
                    .font(.footnote)
                    .foregroundStyle(TRTheme.textDim)
            }
        }
        .navigationTitle(TRL10n.t("settings.sync.details"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(TRTheme.ink)
        .toolbar(.visible, for: .navigationBar)
        .tint(TRTheme.indigo)
    }

    // MARK: - 实时活动

    @ViewBuilder
    private var liveActivitySection: some View {
        Section {
            LabeledContent(TRL10n.t("settings.section.liveactivity")) {
                Text(model.liveActivityState == .active
                    ? TRL10n.t("settings.liveactivity.active")
                    : TRL10n.t("settings.liveactivity.inactive"))
                    .foregroundStyle(TRTheme.textDim)
            }
            switch model.liveActivityState {
            case .denied:
                Text(TRL10n.t("settings.liveactivity.denied"))
                    .font(.footnote)
                    .foregroundStyle(TRTheme.textDim)
            case .active:
                Button(TRL10n.t("settings.liveactivity.stop")) {
                    model.endLiveActivity()
                }
                .tint(TRTheme.indigo)
                .accessibilityIdentifier("tr.settings.stopLiveActivity")
            case .inactive:
                Button(TRL10n.t("settings.liveactivity.start")) {
                    model.startLiveActivity()
                }
                .disabled(model.snapshot.isEmpty)
                .accessibilityIdentifier("tr.settings.startLiveActivity")
                if model.snapshot.isEmpty {
                    Text(TRL10n.t("settings.liveactivity.needssource"))
                        .font(.footnote)
                        .foregroundStyle(TRTheme.textDim)
                }
            }
        }
        .onAppear { model.refreshLiveActivityState() }
    }

    private var originStatus: String {
        switch model.origin {
        case .demo: TRL10n.t("origin.demo.status")
        case .macSync: TRL10n.t("origin.macsync.status")
        case .none: TRL10n.t("origin.none.status")
        }
    }

    private var mobileSyncStatus: String {
        switch model.mobileSyncState {
        case .off: return TRL10n.t("origin.none.status")
        case .pulling: return TRL10n.t("settings.sync.pulling")
        case .waitingForMac: return TRL10n.t("settings.sync.waiting_mac")
        case .waitingForKey: return TRL10n.t("settings.sync.waiting_key")
        case .synced(let date):
            let value = date.formatted(
                Date.FormatStyle.dateTime.hour().minute().locale(TRL10n.locale)
            )
            return TRL10n.f("settings.sync.latest_snapshot", value)
        case .sourceChangeRequiresConfirmation:
            return TRL10n.t("settings.sync.source_change")
        case .failed(let failure): return mobileSyncFailureText(failure)
        }
    }

    private func mobileSyncFailureText(_ failure: MobileSyncFailure) -> String {
        switch failure {
        case .iCloudAccountUnavailable, .iCloudAccountRestricted,
             .iCloudAccountUnknown, .iCloudAuthenticationRequired, .iCloudPermissionDenied:
            return TRL10n.t("settings.sync.error.account")
        case .iCloudTemporarilyUnavailable, .networkUnavailable, .serviceUnavailable, .rateLimited, .syncConflict:
            return TRL10n.t("settings.sync.error.temporary")
        case .remoteRecordUnavailable:
            return TRL10n.t("settings.sync.error.remote")
        case .syncKeyUnavailable:
            return TRL10n.t("settings.sync.error.key")
        case .untrustedRemotePayload, .localReplayStateUnavailable:
            return TRL10n.t("settings.sync.error.security")
        }
    }

    private var syncStatusIcon: String {
        switch model.mobileSyncState {
        case .synced: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .sourceChangeRequiresConfirmation: "desktopcomputer.trianglebadge.exclamationmark"
        case .pulling: "arrow.triangle.2.circlepath"
        case .waitingForMac, .waitingForKey: "clock"
        case .off: "circle"
        }
    }

    private var syncStatusColor: Color {
        switch model.mobileSyncState {
        case .synced: TRTheme.success
        case .failed, .sourceChangeRequiresConfirmation: TRTheme.warning
        case .pulling: TRTheme.indigo
        case .waitingForMac, .waitingForKey, .off: TRTheme.textDim
        }
    }

    private func detailTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle.dateTime
                .hour()
                .minute()
                .second()
                .locale(TRL10n.locale)
        )
    }

    private var iCloudHealthText: String {
        if case .failed(let failure) = model.mobileSyncState {
            switch failure {
            case .iCloudAccountUnavailable, .iCloudAccountRestricted,
                 .iCloudAccountUnknown, .iCloudAuthenticationRequired,
                 .iCloudPermissionDenied:
                return TRL10n.t("settings.sync.health.unavailable")
            default:
                return TRL10n.t("settings.sync.health.pending")
            }
        }
        switch model.mobileSyncState {
        case .waitingForMac, .waitingForKey, .synced, .sourceChangeRequiresConfirmation:
            return TRL10n.t("settings.sync.health.available")
        case .off, .pulling, .failed:
            return TRL10n.t("settings.sync.health.pending")
        }
    }

    private var iCloudHealthIcon: String {
        iCloudHealthText == TRL10n.t("settings.sync.health.available")
            ? "checkmark.circle.fill"
            : "icloud.slash"
    }

    private var iCloudHealthColor: Color {
        iCloudHealthText == TRL10n.t("settings.sync.health.available")
            ? TRTheme.success
            : TRTheme.textDim
    }

    private var syncKeyHealthText: String {
        switch model.mobileSyncState {
        case .synced, .sourceChangeRequiresConfirmation:
            return TRL10n.t("settings.sync.health.ready")
        case .waitingForKey:
            return TRL10n.t("settings.sync.health.waiting")
        case .off, .pulling, .waitingForMac, .failed:
            return TRL10n.t("settings.sync.health.pending")
        }
    }

    private var syncKeyHealthIcon: String {
        switch model.mobileSyncState {
        case .synced, .sourceChangeRequiresConfirmation: "key.fill"
        case .waitingForKey: "key.horizontal"
        case .off, .pulling, .waitingForMac, .failed: "questionmark.circle"
        }
    }

    private var syncKeyHealthColor: Color {
        switch model.mobileSyncState {
        case .synced, .sourceChangeRequiresConfirmation: TRTheme.success
        default: TRTheme.textDim
        }
    }

    private var macSnapshotHealthText: String {
        switch model.mobileSyncState {
        case .waitingForMac:
            return TRL10n.t("settings.sync.health.not_found")
        case .waitingForKey, .synced, .sourceChangeRequiresConfirmation:
            return TRL10n.t("settings.sync.health.found")
        case .off, .pulling, .failed:
            return TRL10n.t("settings.sync.health.pending")
        }
    }

    private var macSnapshotHealthIcon: String {
        switch model.mobileSyncState {
        case .waitingForKey, .synced, .sourceChangeRequiresConfirmation: "desktopcomputer"
        case .waitingForMac: "desktopcomputer.trianglebadge.exclamationmark"
        case .off, .pulling, .failed: "questionmark.circle"
        }
    }

    private var macSnapshotHealthColor: Color {
        switch model.mobileSyncState {
        case .waitingForKey, .synced, .sourceChangeRequiresConfirmation: TRTheme.success
        default: TRTheme.textDim
        }
    }

    // MARK: - 小组件

    /// Purely informational. Widgets and controls are added in system UI, so there
    /// are no fake in-app toggles pretending otherwise.
    private var devicesSection: some View {
        Section(TRL10n.t("settings.section.devices")) {
            NavigationLink {
                widgetsDetailsPage
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TRL10n.t("settings.section.widgets"))
                        Text(TRL10n.t("settings.widgets.subtitle"))
                            .font(.caption)
                            .foregroundStyle(TRTheme.textDim)
                    }
                } icon: {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(TRTheme.indigo)
                }
            }

            NavigationLink {
                watchDetailsPage
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TRL10n.t("settings.section.watch"))
                        Text(watchSummary)
                            .font(.caption)
                            .foregroundStyle(TRTheme.textDim)
                    }
                } icon: {
                    Image(systemName: "applewatch")
                        .foregroundStyle(TRTheme.indigo)
                }
            }
        }
    }

    private func howTo(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(TRTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(TRTheme.indigo)
        }
    }

    private var widgetsDetailsPage: some View {
        Form {
            Section {
                howTo("square.grid.2x2", TRL10n.t("settings.widgets.home"))
                howTo("lock", TRL10n.t("settings.widgets.lock"))
                howTo("button.horizontal.top.press", TRL10n.t("settings.widgets.control"))
            }
        }
        .navigationTitle(TRL10n.t("settings.section.widgets"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(TRTheme.ink)
        .toolbar(.visible, for: .navigationBar)
        .tint(TRTheme.indigo)
    }

    // MARK: - Apple Watch

    private var watchDetailsPage: some View {
        Form {
            Section {
                watchDetails
            }
        }
        .navigationTitle(TRL10n.t("settings.section.watch"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(TRTheme.ink)
        .toolbar(.visible, for: .navigationBar)
        .tint(TRTheme.indigo)
    }

    @ViewBuilder
    private var watchDetails: some View {
        let status = model.watchStatus
        if status.isSupported {
            LabeledContent(TRL10n.t("settings.section.watch")) {
                Text(status.isPaired ? TRL10n.t("settings.watch.paired") : TRL10n.t("settings.watch.notpaired"))
                    .foregroundStyle(TRTheme.textDim)
            }
            Text(status.isWatchAppInstalled
                ? TRL10n.t("settings.watch.installed")
                : TRL10n.t("settings.watch.notinstalled"))
                .font(.footnote)
                .foregroundStyle(TRTheme.textDim)
            Text(status.lastPushedAt.map {
                TRL10n.f("settings.watch.lastsync", UsageFormatting.freshnessDescription(since: $0, now: Date()))
            } ?? TRL10n.t("settings.watch.neversync"))
                .font(.footnote)
                .foregroundStyle(TRTheme.textDim)
        } else {
            Text(TRL10n.t("settings.watch.unsupported"))
                .font(.footnote)
                .foregroundStyle(TRTheme.textDim)
        }
    }

    private var watchSummary: String {
        let status = model.watchStatus
        guard status.isSupported else {
            return TRL10n.t("settings.watch.unsupported")
        }
        return status.isPaired
            ? TRL10n.t("settings.watch.paired")
            : TRL10n.t("settings.watch.notpaired")
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section(TRL10n.t("settings.section.about")) {
            NavigationLink {
                aboutDetailsPage
            } label: {
                Label(TRL10n.t("settings.about.title"), systemImage: "info.circle")
            }
            .accessibilityIdentifier("tr.settings.about")
        }
    }

    private var aboutDetailsPage: some View {
        Form {
            Section {
                LabeledContent(TRL10n.t("settings.version")) {
                    Text(Self.version).foregroundStyle(TRTheme.textDim)
                }
            }
            Section {
                Text(TRL10n.t("privacy.statement"))
                    .font(.footnote)
                    .foregroundStyle(TRTheme.textDim)
                    .accessibilityIdentifier("tr.settings.privacy")
            }
        }
        .navigationTitle(TRL10n.t("settings.about.title"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(TRTheme.ink)
        .toolbar(.visible, for: .navigationBar)
        .tint(TRTheme.indigo)
    }

    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

private extension MobileSyncState {
    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

#Preview("Settings") {
    SettingsTab()
        .environment(AppModel(arguments: ["-tr-demo", "concept"]))
        .preferredColorScheme(.dark)
}
