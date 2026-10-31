import AppKit
import Combine
import SwiftUI

@MainActor
final class DashboardVisibility: ObservableObject {
    @Published private(set) var isVisible = false
    /// Ordered in or minimized, even while covered. Unlike `isVisible`, this
    /// only turns false when the window closes, so occlusion or minimizing
    /// never discards an unsaved draft.
    @Published private(set) var isWindowOpen = false

    func setWindowOpen(_ open: Bool) {
        guard open != isWindowOpen else { return }
        isWindowOpen = open
    }

    @discardableResult
    func setVisible(_ visible: Bool) -> Bool {
        let becameVisible = visible && !isVisible
        guard visible != isVisible else { return false }
        isVisible = visible
        return becameVisible
    }

    @discardableResult
    func update(from window: NSWindow) -> Bool {
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
    private let onBecameVisible: () -> Void
    private var visibilityObservers: [NSObjectProtocol] = []
    private var backgroundLightnessObserver: AnyCancellable?

    /// The pre-macOS 26 window fill. Bluer than `DashboardTheme.canvas` on
    /// purpose — it is only ever seen at the window's own edges during a live
    /// resize, where a flat ink reads better than the canvas token. It follows
    /// the same lightness mapping so those edges do not stay black once the
    /// user lifts the Dashboard background.
    private static let windowBaseHex: UInt = 0x090D14

    init(
        store: UsageStore,
        feedStore: AIFeedStore,
        launchAtLogin: LaunchAtLoginManager,
        onBecameVisible: @escaping () -> Void
    ) {
        self.onBecameVisible = onBecameVisible
        let navigator = self.navigator
        let visibility = self.visibility
        let hosting = NSHostingController(
            rootView: DashboardWindowRoot(visibility: visibility) {
                DashboardView(
                    store: store,
                    feedStore: feedStore,
                    launchAtLogin: launchAtLogin,
                    navigator: navigator,
                    visibility: visibility
                )
            }
        )
        FixedHostingWindowSizing.configure(hosting)

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
            window.backgroundColor = Self.windowBackgroundColor(
                lightness: PreferencesStore.shared.dashboardBackgroundLightness
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
                        self.visibility.setWindowOpen(false)
                    } else if self.visibility.update(from: window) {
                        self.onBecameVisible()
                    }
                }
            }
        }

        // macOS 26 draws a clear window over system glass, so only the older
        // flat-fill path has anything to keep in sync with the preference.
        if #unavailable(macOS 26.0) {
            backgroundLightnessObserver = PreferencesStore.shared
                .$dashboardBackgroundLightness
                .receive(on: RunLoop.main)
                .sink { [weak self] lightness in
                    self?.window?.backgroundColor = Self.windowBackgroundColor(
                        lightness: lightness
                    )
                }
        }
    }

    private static func windowBackgroundColor(lightness: Double) -> NSColor {
        let rgb = DashboardSurfaceLightening.lightenedComponents(
            windowBaseHex,
            lightness: lightness
        )
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
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
        let animates = Self.opensWithAnimation(
            wasOnScreen: window.map { $0.isVisible && !$0.isMiniaturized } ?? false,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        visibility.setWindowOpen(true)
        if animates, let window {
            // Build and lay out the new view tree while the window is still
            // off screen. (SwiftUI does not draw it until it is on screen.)
            window.contentView?.layoutSubtreeIfNeeded()
            window.alphaValue = 0
        }
        // The system's document-window open adds a slight zoom that the
        // window server applies to the window as a whole; on its own it is
        // too small to see, so the fade below carries the entrance.
        window?.animationBehavior = animates ? .documentWindow : .none
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Re-assert after SwiftUI configures its toolbar, which can otherwise
        // flip the document title back to visible. The title *property* stays
        // "TokenRemain" for Mission Control / the window switcher.
        window?.titleVisibility = .hidden
        if let window, visibility.update(from: window) {
            onBecameVisible()
        }
        guard animates, let window else {
            window?.alphaValue = 1
            return
        }
        // SwiftUI draws only a window that is on screen, so the page's first
        // draw (~0.2s) happens now, behind alpha 0. Left to this turn's
        // display cycle it ran after the fade had started (a main-queue block
        // runs first), and the page appeared at 75-90% opacity. Draw it here
        // and send it, then fade on the next turn over a drawn page. Only
        // window alpha animates; the frame and the page's layout never do.
        window.layoutIfNeeded()
        CATransaction.flush()
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionTiming.dashboardFadeIn
                context.timingFunction = MotionTiming.dashboardFadeCurve
                window.animator().alphaValue = 1
            }
        }
    }

    /// A window that is already on screen just comes to the front; one being
    /// opened animates in, unless Reduce Motion is on.
    nonisolated static func opensWithAnimation(wasOnScreen: Bool, reduceMotion: Bool) -> Bool {
        !wasOnScreen && !reduceMotion
    }
}

/// A closed Dashboard keeps its window, frame and selected section for the
/// next open, but not a live view tree: SwiftUI would otherwise re-evaluate and
/// lay out the last section — keychain-backed credential rows included — on
/// every UsageStore change while nobody can see it.
private struct DashboardWindowRoot<Content: View>: View {
    @ObservedObject var visibility: DashboardVisibility
    @ViewBuilder let content: () -> Content

    var body: some View {
        if visibility.isWindowOpen {
            content()
        } else {
            Color.clear
        }
    }
}
