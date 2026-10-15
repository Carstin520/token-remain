import AppKit
import SwiftUI

/// Floating panel beside the browser, like the claude.ai guide: opening the
/// site brings the browser forward, so a Dashboard sheet would hide behind it.
@MainActor
final class WebCookieGuideWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WebCookieGuideWindowController()

    private var session: ClaudeCookieGuideSession?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: WebCookieGuideView.width, height: WebCookieGuideView.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(srgbRed: 0x0D / 255, green: 0x0E / 255, blue: 0x10 / 255, alpha: 1)
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

    /// Restarts from the first step; a previous half-finished paste is cancelled.
    func show(store: UsageStore, spec: WebCookieGuideSpec, openingSite: Bool) {
        guard let panel = window else { return }
        session?.end()
        let session = ClaudeCookieGuideSession()
        self.session = session
        panel.title = L10n.format("cookieguide.title", spec.provider.displayName)
        let hosting = NSHostingController(
            rootView: WebCookieGuideView(
                store: store,
                spec: spec,
                browser: .systemDefault,
                action: session.action,
                onClose: { [weak self] in self?.close() }
            )
        )
        FixedHostingWindowSizing.configure(hosting)
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: WebCookieGuideView.width, height: WebCookieGuideView.height))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.maxY - panel.frame.height - 24
            ))
        }
        panel.orderFrontRegardless()
        if openingSite { spec.openSite() }
    }

    func windowWillClose(_ notification: Notification) {
        session?.end()
        session = nil
        window?.contentViewController = nil
    }
}
