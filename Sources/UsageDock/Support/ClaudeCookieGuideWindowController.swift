import AppKit
import SwiftUI

/// One opening of the Cookie guide. It owns the guide's validation so the
/// window can end it deterministically: closing or reopening the guide
/// cancels a paste still being validated, and `UsageStore.saveAPIKey` checks
/// cancellation before it touches the Keychain, so a late result never saves.
@MainActor
final class ClaudeCookieGuideSession {
    let action = AsyncViewAction()

    func end() {
        action.cancel()
    }
}

/// Hosts the claude.ai Cookie guide in a floating panel. Opening claude.ai
/// brings the browser to the front, so a sheet on the Dashboard would sit
/// behind it exactly when the user needs it; the panel stays above the browser
/// while they follow the steps there.
@MainActor
final class ClaudeCookieGuideWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ClaudeCookieGuideWindowController()

    private var session: ClaudeCookieGuideSession?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: ClaudeCookieGuideView.width, height: ClaudeCookieGuideView.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = L10n.text("claude.guide.title")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(
            srgbRed: 0x0D / 255, green: 0x0E / 255, blue: 0x10 / 255, alpha: 1
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Starts the guide from its first step and, when asked, opens claude.ai in
    /// the user's default browser. Reopening restarts the flow rather than
    /// resuming a half-finished paste, so the previous session ends first.
    func show(store: UsageStore, openingSite: Bool) {
        guard let panel = window else { return }
        session?.end()
        let session = ClaudeCookieGuideSession()
        self.session = session
        let hosting = NSHostingController(
            rootView: ClaudeCookieGuideView(
                store: store,
                browser: .systemDefault,
                action: session.action,
                onClose: { [weak self] in self?.close() }
            )
        )
        // The panel has a fixed size; SwiftUI must never push a measured size
        // back into it (see script/verify_launch_surface_isolation.sh).
        FixedHostingWindowSizing.configure(hosting)
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: ClaudeCookieGuideView.width, height: ClaudeCookieGuideView.height))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.maxY - panel.frame.height - 24
            ))
        }
        panel.orderFrontRegardless()
        if openingSite {
            ClaudeCookieGuideView.openClaudeSite()
        }
    }

    /// Closing ends the session explicitly instead of relying on the hosted
    /// view being deallocated, which SwiftUI does on its own schedule.
    func windowWillClose(_ notification: Notification) {
        session?.end()
        session = nil
        window?.contentViewController = nil
    }
}
