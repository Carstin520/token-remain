import SwiftUI
import TokenRemainKit

struct SettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                sourceSection($model)
                liveActivitySection
                widgetsSection
                watchSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(TRTheme.ink)
            .navigationTitle(TRL10n.t("tab.settings"))
        }
    }

    // MARK: - 数据源

    private func sourceSection(_ model: Bindable<AppModel>) -> some View {
        Section {
            LabeledContent(TRL10n.t("settings.origin.row")) {
                Text(self.model.snapshot.isDemo
                    ? TRL10n.t("origin.demo.status")
                    : TRL10n.t("origin.none.status"))
                    .foregroundStyle(TRTheme.textDim)
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
                .disabled(!model.snapshot.isDemo)
                .accessibilityIdentifier("tr.settings.startLiveActivity")
                if !model.snapshot.isDemo {
                    Text(TRL10n.t("settings.liveactivity.needsdemo"))
                        .font(.footnote)
                        .foregroundStyle(TRTheme.textDim)
                }
            }
        }
        .onAppear { model.refreshLiveActivityState() }
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
