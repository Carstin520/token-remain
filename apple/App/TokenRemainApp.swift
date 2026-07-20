import AppIntents
import SwiftUI
import TokenRemainKit

@main
struct TokenRemainApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    /// Value of the screenshot-only `-tr-family <name>` argument, if present.
    static var galleryFamily: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-tr-family"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // Screenshot-only seam: render the real widget views for capture.
                if ProcessInfo.processInfo.arguments.contains("-tr-widget-gallery") {
                    WidgetGalleryView(entry: model.entry(at: Date()), family: Self.galleryFamily)
                } else {
                    RootView()
                }
            }
                .environment(model)
                // Dark-only appearance by design; the palette has no light variant.
                .preferredColorScheme(.dark)
                .tint(TRTheme.indigo)
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    model.consumePendingRoute()
                    model.refreshLiveActivityState()
                    model.refresh()
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.route) {
            Tab(TRL10n.t("tab.overview"), systemImage: "circle.inset.filled", value: TRRoute.overview) {
                OverviewTab()
            }
            Tab(TRL10n.t("tab.limits"), systemImage: "square.split.2x1", value: TRRoute.limits) {
                LimitsTab()
            }
            Tab(TRL10n.t("tab.trends"), systemImage: "chart.line.uptrend.xyaxis", value: TRRoute.trends) {
                TrendsTab()
            }
            Tab(TRL10n.t("tab.settings"), systemImage: "gearshape", value: TRRoute.settings) {
                SettingsTab()
            }
        }
        .accessibilityIdentifier("tr.root.tabs")
    }
}

/// Siri / Spotlight phrases in both languages. `RefreshSnapshotIntent` is the same
/// intent the Action Button control runs.
struct TRShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshSnapshotIntent(),
            phrases: [
                "刷新 \(.applicationName) 额度",
                "Refresh \(.applicationName) quota"
            ],
            shortTitle: "Refresh quota",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: OpenTabIntent(tab: .overview),
            phrases: [
                "查看 \(.applicationName)",
                "Open \(.applicationName)"
            ],
            shortTitle: "Open Token Remain",
            systemImageName: "circle.inset.filled"
        )
        AppShortcut(
            intent: StartLiveActivityIntent(),
            phrases: [
                "开始 \(.applicationName) 实时活动",
                "Start \(.applicationName) Live Activity"
            ],
            shortTitle: "Start Live Activity",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: StopLiveActivityIntent(),
            phrases: [
                "停止 \(.applicationName) 实时活动",
                "Stop \(.applicationName) Live Activity"
            ],
            shortTitle: "Stop Live Activity",
            systemImageName: "stop.circle"
        )
    }
}
