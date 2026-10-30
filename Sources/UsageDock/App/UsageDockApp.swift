import AppKit
import Combine
import SwiftUI

/// SwiftUI has no runtime API for Dock presence. Keep the AppKit boundary to
/// this single activation-policy mapping while PreferencesStore remains the
/// persisted source of truth.
enum DockIconVisibility {
    static func activationPolicy(hidden: Bool) -> NSApplication.ActivationPolicy {
        hidden ? .accessory : .regular
    }

    @discardableResult
    @MainActor
    static func apply(hidden: Bool, to application: NSApplication? = nil) -> Bool {
        (application ?? NSApp).setActivationPolicy(activationPolicy(hidden: hidden))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var store = UsageStore()
    private lazy var feedStore = AIFeedStore()
    private lazy var launchAtLogin = LaunchAtLoginManager()
    private var statusBarController: StatusBarController?
    private var feedNotificationObserver: NSObjectProtocol?
    private var dataSourcesNotificationObserver: NSObjectProtocol?
    private var settingsNotificationObserver: NSObjectProtocol?
    private var dockIconCancellable: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
        AppUpdateController.shared.configurePreview(arguments: arguments)
#endif
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

        // Apply the persisted presence choice before creating any windows so a
        // menu-bar-only user never sees a transient Dock icon during launch.
        let preferences = PreferencesStore.shared
        DockIconVisibility.apply(hidden: preferences.dockIconHidden)
        dockIconCancellable = preferences.$dockIconHidden
            .dropFirst()
            .removeDuplicates()
            .sink { hidden in
                DockIconVisibility.apply(hidden: hidden)
            }
        statusBarController = StatusBarController(
            store: store,
            feedStore: feedStore,
            launchAtLogin: launchAtLogin
        )
        DirectSyncController.shared.attach(to: store)
        feedNotificationObserver = NotificationCenter.default.addObserver(
            forName: .tokenRemainOpenAIFeed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusBarController?.showDashboard(section: .overview)
            }
        }
        dataSourcesNotificationObserver = NotificationCenter.default.addObserver(
            forName: .tokenRemainOpenDataSources,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusBarController?.showDashboard(section: .dataSources)
            }
        }
        settingsNotificationObserver = NotificationCenter.default.addObserver(
            forName: .tokenRemainOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusBarController?.showDashboard(section: .settings)
            }
        }
#if TOKENREMAIN_CLOUD_SYNC
        // Website-distributed production builds update themselves through the
        // signed Sparkle appcast. Development builds never start the updater,
        // so they cannot replace the stable CloudKit-enabled application.
        AppUpdateController.shared.start()
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
        } else if arguments.contains("--measure-hidden-dashboard") {
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController?.showDashboard(section: .overview)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.statusBarController?.closeDashboardForPerformanceMeasurement()
                }
            }
        } else if arguments.contains("--open-dashboard") || arguments.contains("--open-ai-feed") {
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController?.showDashboard(section: .overview)
            }
        } else if arguments.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.statusBarController?.openPopoverForPreview()
            }
        } else if arguments.contains("--menu-bar-only") {
            // Performance/QA hook: keep the real app bundle and menu-bar stack
            // running without creating the Dashboard, so hidden-idle energy can
            // be sampled reproducibly without UI automation.
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController?.showDashboard(section: .overview)
            }
        }
    }

    /// The Dock click is fully handled here, so the system's default reopen
    /// is declined: with only the placeholder Settings scene declared, letting
    /// it run opened an empty "TokenRemain Settings" window beside the
    /// Dashboard.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("--open-popover") {
            statusBarController?.openPopoverForPreview()
            return false
        }
        statusBarController?.showDashboard(section: .overview)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
#if TOKENREMAIN_CLOUD_SYNC
        AppUpdateController.shared.checkIfDue()
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

    /// A SwiftUI App must declare a scene; the real windows are AppKit
    /// (`StatusBarController`), and settings are a Dashboard section. The app
    /// menu's Settings item and ⌘, open that section, and the placeholder
    /// window closes itself if the system opens it anyway.
    var body: some Scene {
        Settings {
            SettingsPlaceholderCloser()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("nav.settings") + "…") {
                    NotificationCenter.default.post(name: .tokenRemainOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Content of the placeholder Settings window. The menu item and ⌘, never
/// open it, so it only appears when SwiftUI does on its own: on macOS 27 it
/// opens this scene at every launch (declining `applicationShouldOpenUntitledFile`
/// does not stop it), and in 1.4.7 that left an empty "TokenRemain Settings"
/// window. It hides at once and closes without navigating: the app has
/// already shown the window that context needs.
struct SettingsPlaceholderCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CloserView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CloserView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.alphaValue = 0
            DispatchQueue.main.async {
                window.close()
            }
        }
    }
}
