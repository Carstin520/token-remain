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
                    widgetsSection
                    watchSection
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
                TRL10n.t("settings.macsync.toggle"),
                isOn: Binding(
                    get: { self.model.isMacSyncEnabled },
                    set: { self.model.setMacSyncEnabled($0) }
                )
            )
            .tint(TRTheme.indigo)
            .accessibilityIdentifier("tr.settings.macSyncToggle")
            if self.model.isMacSyncEnabled {
                Text(mobileSyncStatus)
                    .font(.footnote)
                    .foregroundStyle(TRTheme.textDim)
                if let timing = self.model.latestSyncTiming {
                    LabeledContent(
                        TRL10n.current == .zhHans ? "Provider 采集" : "Provider captured"
                    ) {
                        Text(timing.providerCapturedAt.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(TRTheme.textDim)
                    }
                    LabeledContent(
                        TRL10n.current == .zhHans ? "手机呈现" : "Phone rendered"
                    ) {
                        Text(timing.phoneRenderedAt.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(TRTheme.textDim)
                    }
                }
                if let summary = self.model.syncLatencySummary {
                    let format = TRL10n.current == .zhHans
                        ? "前台时延 · p50 %.0f 秒 · p95 %.0f 秒 · 最大 %.0f 秒 · n=%d"
                        : "Foreground latency · p50 %.0fs · p95 %.0fs · max %.0fs · n=%d"
                    Text(String(
                        format: format,
                        summary.p50Seconds,
                        summary.p95Seconds,
                        summary.maximumSeconds,
                        summary.sampleCount
                    ))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textDim)
                }
                if case .sourceChangeRequiresConfirmation = self.model.mobileSyncState {
                    Button(TRL10n.t("settings.macsync.confirm")) {
                        self.model.acceptPendingMacSource()
                    }
                    .tint(TRTheme.indigo)
                } else {
                    Button(TRL10n.t("settings.macsync.refresh")) {
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
        } footer: {
            Text(TRL10n.t("settings.demo.footer"))
        }
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
        case .pulling: return TRL10n.current == .zhHans ? "正在安全拉取…" : "Securely pulling…"
        case .waitingForMac: return TRL10n.current == .zhHans ? "等待 Mac 上传第一份快照" : "Waiting for the first Mac snapshot"
        case .waitingForKey: return TRL10n.current == .zhHans ? "等待 iCloud 钥匙串同步密钥" : "Waiting for the iCloud Keychain sync key"
        case .synced(let date):
            let value = date.formatted(date: .omitted, time: .shortened)
            return TRL10n.current == .zhHans ? "已同步 · \(value)" : "Synced · \(value)"
        case .sourceChangeRequiresConfirmation:
            return TRL10n.current == .zhHans ? "检测到新的 Mac 数据源，需要确认" : "A new Mac source needs confirmation"
        case .failed(let failure): return mobileSyncFailureText(failure)
        }
    }

    private func mobileSyncFailureText(_ failure: MobileSyncFailure) -> String {
        let zh = TRL10n.current == .zhHans
        switch failure {
        case .iCloudAccountUnavailable, .iCloudAccountRestricted,
             .iCloudAccountUnknown, .iCloudAuthenticationRequired, .iCloudPermissionDenied:
            return zh ? "iCloud 账户不可用或未授权" : "iCloud account unavailable or unauthorized"
        case .iCloudTemporarilyUnavailable, .networkUnavailable, .serviceUnavailable, .rateLimited, .syncConflict:
            return zh ? "iCloud 暂不可用，稍后可重试" : "iCloud is temporarily unavailable; retry later"
        case .remoteRecordUnavailable:
            return zh ? "等待 Mac 上传快照" : "Waiting for a Mac snapshot"
        case .syncKeyUnavailable:
            return zh ? "等待 iCloud 钥匙串同步密钥" : "Waiting for the iCloud Keychain sync key"
        case .untrustedRemotePayload, .localReplayStateUnavailable:
            return zh ? "远端快照未通过安全校验，已保留旧数据" : "Remote snapshot failed security validation; old data was kept"
        }
    }

    // MARK: - 小组件

    /// Purely informational. Widgets and controls are added in system UI, so there
    /// are no fake in-app toggles pretending otherwise.
    private var widgetsSection: some View {
        Section(TRL10n.t("settings.section.widgets")) {
            howTo("square.grid.2x2", TRL10n.t("settings.widgets.home"))
            howTo("lock", TRL10n.t("settings.widgets.lock"))
            howTo("button.horizontal.top.press", TRL10n.t("settings.widgets.control"))
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

    // MARK: - Apple Watch

    private var watchSection: some View {
        Section(TRL10n.t("settings.section.watch")) {
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
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section(TRL10n.t("settings.section.about")) {
            LabeledContent(TRL10n.t("settings.version")) {
                Text(Self.version).foregroundStyle(TRTheme.textDim)
            }
            Text(TRL10n.t("privacy.statement"))
                .font(.footnote)
                .foregroundStyle(TRTheme.textDim)
                .accessibilityIdentifier("tr.settings.privacy")
        }
    }

    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview("Settings") {
    SettingsTab()
        .environment(AppModel(arguments: ["-tr-demo", "concept"]))
        .preferredColorScheme(.dark)
}
