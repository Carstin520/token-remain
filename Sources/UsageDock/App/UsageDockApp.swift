import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var store = UsageStore()
    private lazy var feedStore = AIFeedStore()
    private lazy var launchAtLogin = LaunchAtLoginManager()
    private var statusBarController: StatusBarController?
    private var feedNotificationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
#if TOKENREMAIN_APP_STORE_CANDIDATE
        if arguments.contains("--provider-compatibility-audit") {
            let environment = argument(after: "--audit-environment", in: arguments) ?? "unspecified"
            NSApp.setActivationPolicy(.prohibited)
            Task {
                let report = await AppStoreSandboxProviderAudit.run(environment: environment)
                try? FileHandle.standardOutput.write(contentsOf: report)
                try? FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
                NSApp.terminate(nil)
            }
            return
        }
#endif

        // TokenRemain is a desktop app with a persistent Dashboard and a
        // companion menu-bar status item.
        NSApp.setActivationPolicy(.regular)
        statusBarController = StatusBarController(
            store: store,
            feedStore: feedStore,
            launchAtLogin: launchAtLogin
        )
        feedNotificationObserver = NotificationCenter.default.addObserver(
            forName: .tokenRemainOpenAIFeed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusBarController?.showDashboard(section: .overview)
            }
        }
#if TOKENREMAIN_CLOUD_SYNC
        CrossDeviceSyncController.shared.attach(to: store)
#endif

        if arguments.contains("--enable-launch-at-login") {
            launchAtLogin.setEnabled(true)
        }

        // Dev/QA hook: jump straight to a named dashboard section (rawValue),
        // e.g. `--open-section trends`. Mirrors the other launch-preview flags.
        if let sectionIndex = arguments.firstIndex(of: "--open-section"),
           arguments.indices.contains(sectionIndex + 1),
           let section = DashboardSection(rawValue: arguments[sectionIndex + 1]) {
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController?.showDashboard(section: section)
            }
        } else if arguments.contains("--open-dashboard") || arguments.contains("--open-ai-feed") {
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController?.showDashboard(section: .overview)
            }
        } else if arguments.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.statusBarController?.openPopoverForPreview()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController?.showDashboard(section: .overview)
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusBarController?.showDashboard(section: .overview)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
#if TOKENREMAIN_CLOUD_SYNC
        CrossDeviceSyncController.shared.checkNow()
#endif
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { [weak self] in
            await self?.feedStore.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        feedStore.didFailToRegisterForRemoteNotifications(error)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

#if TOKENREMAIN_APP_STORE_CANDIDATE
    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
#endif
}

@main
struct UsageDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
