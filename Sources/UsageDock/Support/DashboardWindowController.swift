import AppKit
import SwiftUI

/// Hosts the SwiftUI Dashboard in a standalone window. This is the only AppKit
/// window glue in the app; it is deliberately isolated so the rest of the
/// Dashboard stays pure SwiftUI.
///
/// The app remains a menu-bar-first `.accessory` agent: opening the Dashboard
/// activates the app and fronts the window without switching to a regular
/// Dock-resident activation policy.
@MainActor
final class DashboardWindowController: NSWindowController {
    private let navigator = DashboardNavigator()

    init(store: UsageStore, feedStore: AIFeedStore, launchAtLogin: LaunchAtLoginManager) {
        let hosting = NSHostingController(
            rootView: DashboardView(
                store: store,
                feedStore: feedStore,
                launchAtLogin: launchAtLogin,
                navigator: navigator
            )
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "UsageDock"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0x09 / 255, green: 0x0D / 255, blue: 0x14 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 640)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("UsageDockDashboard")
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the Dashboard, optionally jumping to a specific section, and brings
    /// it to the front even though the app is a menu-bar accessory.
    func show(section: DashboardSection? = nil) {
        if let section {
            navigator.selection = section
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
