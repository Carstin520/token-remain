import AppKit
import Combine
import SwiftUI

@MainActor
final class DashboardVisibility: ObservableObject {
    @Published private(set) var isVisible = false

    func setVisible(_ visible: Bool) {
        isVisible = visible
    }

    func update(from window: NSWindow) {
        setVisible(
            window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        )
    }
}

/// Hosts the SwiftUI Dashboard in a standalone window. This is the only AppKit
/// window glue in the app; it is deliberately isolated so the rest of the
/// Dashboard stays pure SwiftUI.
///
/// TokenRemain is a regular Dock-resident desktop app. The menu-bar status
/// item is a companion surface, while this controller owns the primary window.
@MainActor
final class DashboardWindowController: NSWindowController {
    private let navigator = DashboardNavigator()
    private let visibility = DashboardVisibility()
    private var visibilityObservers: [NSObjectProtocol] = []

    init(store: UsageStore, feedStore: AIFeedStore, launchAtLogin: LaunchAtLoginManager) {
        let hosting = NSHostingController(
            rootView: DashboardView(
                store: store,
                feedStore: feedStore,
                launchAtLogin: launchAtLogin,
                navigator: navigator,
                visibility: visibility
            )
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        // Keep the real window title for Mission Control, the window switcher and
        // accessibility, but leave the visible chrome to the compact sidebar mark.
        window.title = "TokenRemain"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        if #available(macOS 26.0, *) {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.backgroundColor = NSColor(
                srgbRed: 0x09 / 255,
                green: 0x0D / 255,
                blue: 0x14 / 255,
                alpha: 1
            )
        }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 640)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("UsageDockDashboard")
        window.center()

        super.init(window: window)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification
        ]
        visibilityObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let window = self.window else { return }
                    if name == NSWindow.willCloseNotification {
                        self.visibility.setVisible(false)
                    } else {
                        self.visibility.update(from: window)
                    }
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Shows the Dashboard, optionally jumping to a specific section, and
    /// brings the desktop app to the front.
    func show(section: DashboardSection? = nil) {
        if let section {
            navigator.selection = section
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Re-assert after SwiftUI configures its toolbar, which can otherwise
        // flip the document title back to visible. The title *property* stays
        // "TokenRemain" for Mission Control / the window switcher.
        window?.titleVisibility = .hidden
        if let window {
            visibility.update(from: window)
        }
    }
}
