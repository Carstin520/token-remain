import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let feedStore = AIFeedStore()
    private let launchAtLogin = LaunchAtLoginManager()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // This is intentionally a menu-bar-only utility: no Dock icon or main window.
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(
            store: store,
            feedStore: feedStore,
            launchAtLogin: launchAtLogin
        )

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

        if arguments.contains("--open-dashboard") || arguments.contains("--open-ai-feed") {
            DispatchQueue.main.async { [weak self] in
                let section: DashboardSection = arguments.contains("--open-ai-feed") ? .aiFeed : .overview
                self?.statusBarController?.openDashboardForPreview(section: section)
            }
        }

        if arguments.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.statusBarController?.openPopoverForPreview()
            }
        }
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
