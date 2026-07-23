import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let feedStore = AIFeedStore()
    private let launchAtLogin = LaunchAtLoginManager()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TokenRemain is a desktop app with a persistent Dashboard and a
        // companion menu-bar status item.
        NSApp.setActivationPolicy(.regular)
        statusBarController = StatusBarController(
            store: store,
            feedStore: feedStore,
            launchAtLogin: launchAtLogin
        )
#if TOKENREMAIN_CLOUD_SYNC
        CrossDeviceSyncController.shared.attach(to: store, feedStore: feedStore)
#endif

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--enable-launch-at-login") {
            launchAtLogin.setEnabled(true)
        }

        if let flagIndex = arguments.firstIndex(of: "--import-feed-config"),
           arguments.indices.contains(flagIndex + 1) {
            let configURL = URL(fileURLWithPath: arguments[flagIndex + 1])
            Task { [weak self] in
                await self?.feedStore.importLocalConfiguration(from: configURL)
            }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
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
