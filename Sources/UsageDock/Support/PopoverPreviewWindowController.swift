import AppKit
import SwiftUI

#if DEBUG
/// Hosts the real menu content in a standard window so visual-regression tools
/// can inspect pointer interactions that are otherwise hidden inside NSPopover.
@MainActor
final class PopoverPreviewWindowController: NSWindowController {
    init(
        store: UsageStore,
        launchAtLogin: LaunchAtLoginManager,
        onOpenDashboard: @escaping (DashboardSection) -> Void
    ) {
        let hosting = NSHostingController(
            rootView: UsageMenuView(
                store: store,
                launchAtLogin: launchAtLogin,
                onOpenDashboard: onOpenDashboard
            )
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "UsageDock Popover Preview"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0x09 / 255, green: 0x0D / 255, blue: 0x14 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 380, height: 720))
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif
