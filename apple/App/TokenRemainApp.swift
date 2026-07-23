import AppIntents
import CloudKit
import SwiftUI
import TokenRemainKit
import TokenRemainSyncKit
import UIKit

extension Notification.Name {
    static let tokenRemainRemoteSyncSnapshot = Notification.Name("tokenRemain.remoteSyncSnapshot")
    static let tokenRemainRemoteSyncCleared = Notification.Name("tokenRemain.remoteSyncCleared")
}

@MainActor
final class TokenRemainAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard MobileSyncRemoteNotification.shouldTriggerPull(for: userInfo) else {
            completionHandler(.noData)
            return
        }
        // The user-controlled App Group setting is the authorization boundary
        // for every background pull. A delayed push cannot re-enable sync.
        guard TRSettingsStore.shared.origin == .macSync else {
            completionHandler(.noData)
            return
        }
        Task {
            let outcome = await MobileSyncClient.shared.pull()
            // Re-check after the asynchronous CloudKit call in case the user
            // disabled sync while it was in flight.
            guard TRSettingsStore.shared.origin == .macSync else {
                completionHandler(.noData)
                return
            }
            switch outcome {
            case .updated(let delivery):
                let snapshot = delivery.snapshot
                // Persist a validated fallback before acknowledging the push.
                // If SwiftUI has not installed its observer yet, the next
                // foreground refresh still reads this exact verified snapshot.
                let localSnapshot = MobileSnapshotAdapter.usageSnapshot(from: snapshot)
                SnapshotStore.shared.write(localSnapshot)
                SnapshotHistoryStore.shared.append(localSnapshot)
                MobileDailyUsageHistoryStore.shared.replace(
                    with: snapshot.dailyUsageHistory
                )
                MobileCuratedFeedStore.shared.replace(with: snapshot.curatedFeed)
                WidgetReload.all()
                NotificationCenter.default.post(
                    name: .tokenRemainRemoteSyncSnapshot,
                    object: delivery
                )
                completionHandler(.newData)
            case .noChange(.noRemoteSnapshot):
                // A deleted private record/zone is also a data-erasure signal.
                SnapshotStore.shared.clear()
                SnapshotHistoryStore.shared.clear()
                MobileDailyUsageHistoryStore.shared.clear()
                MobileCuratedFeedStore.shared.clear()
                WidgetReload.all()
                NotificationCenter.default.post(
                    name: .tokenRemainRemoteSyncCleared,
                    object: nil
                )
                completionHandler(.newData)
            default:
                completionHandler(.noData)
            }
        }
    }
}

@main
struct TokenRemainApp: App {
    @UIApplicationDelegateAdaptor(TokenRemainAppDelegate.self) private var appDelegate
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
                .onReceive(NotificationCenter.default.publisher(for: .tokenRemainRemoteSyncSnapshot)) { notification in
                    guard model.isMacSyncEnabled else { return }
                    guard let delivery = notification.object as? MobileSyncDelivery else { return }
                    model.applySyncedDelivery(delivery)
                }
                .onReceive(NotificationCenter.default.publisher(for: .tokenRemainRemoteSyncCleared)) { _ in
                    guard model.isMacSyncEnabled else { return }
                    model.handleRemoteSyncCleared()
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    Task { await model.handleICloudAccountChanged() }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    model.consumePendingRoute()
                    model.refreshLiveActivityState()
                    model.refresh()
                }
                // CloudKit silent pushes remain the low-latency path. While the
                // app is visible, a 45-second reconciliation also catches a
                // missed/coalesced push. Keying the task to foreground state
                // makes the first pull immediate instead of allowing a launch
                // race to sleep for one interval while the scene is inactive.
                .task(id: ForegroundSyncTaskID(
                    isEnabled: model.isMacSyncEnabled,
                    isActive: scenePhase == .active
                )) {
                    guard model.isMacSyncEnabled, scenePhase == .active else { return }
                    var retryAttempt = 0
                    while !Task.isCancelled {
                        await model.pullMacSync()
                        let delay = model.automaticSyncRetryDelay(afterAttempt: retryAttempt)
                        if case .synced = model.mobileSyncState {
                            retryAttempt = 0
                        } else {
                            retryAttempt += 1
                        }
                        try? await Task.sleep(for: .seconds(delay))
                    }
                }
                .alert(item: syncGuidanceBinding) { guidance in
                    Alert(
                        title: Text(syncGuidanceTitle(guidance)),
                        message: Text(syncGuidanceMessage(guidance)),
                        primaryButton: .default(Text(TRL10n.t("sync.guidance.review"))) {
                            model.route = .settings
                            model.dismissSyncGuidance()
                        },
                        secondaryButton: .cancel(Text(TRL10n.t("sync.guidance.later"))) {
                            model.dismissSyncGuidance()
                        }
                    )
                }
        }
    }

    private var syncGuidanceBinding: Binding<MobileSyncGuidance?> {
        Binding(
            get: { model.syncGuidance },
            set: { value in
                if value == nil {
                    model.dismissSyncGuidance()
                }
            }
        )
    }

    private func syncGuidanceTitle(_ guidance: MobileSyncGuidance) -> String {
        switch guidance {
        case .openMac: return TRL10n.t("settings.sync.waiting_mac")
        case .checkICloud: return TRL10n.t("settings.sync.error.account")
        case .checkKeychain: return TRL10n.t("settings.sync.error.key")
        }
    }

    private func syncGuidanceMessage(_ guidance: MobileSyncGuidance) -> String {
        switch guidance {
        case .openMac: return TRL10n.t("sync.guidance.mac_message")
        case .checkICloud: return TRL10n.t("sync.guidance.icloud_message")
        case .checkKeychain: return TRL10n.t("sync.guidance.keychain_message")
        }
    }
}

private struct ForegroundSyncTaskID: Equatable {
    let isEnabled: Bool
    let isActive: Bool
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
        // Identity layer: the selected tab is tinted Robot Violet (scoped to the tab
        // bar so the indigo action tint elsewhere is unchanged). A per-item neon glow
        // isn't exposed by the system tab bar API, so this is tint-only.
        .tint(TRTheme.violet)
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
            shortTitle: "Open TokenRemain",
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
