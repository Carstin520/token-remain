import AppKit
import SwiftUI

enum MenuBarPopupPlacement {
    static let anchorGap: CGFloat = 0
    static let minimumArrowInset: CGFloat = 16

    struct Result: Equatable {
        let origin: NSPoint
        let arrowCenterX: CGFloat
    }

    static func resolve(
        anchorFrame: NSRect,
        popupSize: NSSize,
        visibleFrame: NSRect
    ) -> Result {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - popupSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - popupSize.height)
        let desiredX = anchorFrame.midX - (popupSize.width / 2)
        let desiredY = anchorFrame.minY - anchorGap - popupSize.height
        let origin = NSPoint(
            x: min(max(desiredX, visibleFrame.minX), maximumX),
            y: min(max(desiredY, visibleFrame.minY), maximumY)
        )
        let maximumArrowX = max(minimumArrowInset, popupSize.width - minimumArrowInset)
        return Result(
            origin: origin,
            arrowCenterX: min(
                max(anchorFrame.midX - origin.x, minimumArrowInset),
                maximumArrowX
            )
        )
    }
}

@MainActor
private final class MenuBarPopupChromeModel: ObservableObject {
    @Published var arrowCenterX: CGFloat = 190
}

/// macOS 26's standard NSPopover always contributes its own vibrant backdrop.
/// Host the popup in a transparent panel instead so the selected SwiftUI Glass
/// style remains the only blur/refraction source.
@MainActor
final class MenuBarPopupWindowController: NSWindowController {
    private let chromeModel: MenuBarPopupChromeModel
    private weak var anchorButton: NSStatusBarButton?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var preferredSizeObservation: NSKeyValueObservation?

    var isShown: Bool {
        window?.isVisible == true
    }

    init<Content: View>(rootView: Content) {
        let chromeModel = MenuBarPopupChromeModel()
        self.chromeModel = chromeModel
        let hosting = NSHostingController(
            rootView: MenuBarPopupChrome(model: chromeModel) {
                rootView
            }
        )
        hosting.sizingOptions = [.preferredContentSize]
        hosting.safeAreaRegions = []

        let panel = MenuBarPopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 700),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow

        hosting.view.wantsLayer = true
        hosting.view.layer?.masksToBounds = false

        super.init(window: panel)

        preferredSizeObservation = hosting.observe(
            \.preferredContentSize,
            options: [.initial, .new]
        ) { [weak self] hosting, _ in
            DispatchQueue.main.async { [weak self, weak hosting] in
                guard let self, let hosting else { return }
                self.applyPreferredContentSize(hosting.preferredContentSize)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(relativeTo button: NSStatusBarButton, activateForVisualTesting: Bool = false) {
        show(
            relativeTo: button,
            activateForVisualTesting: activateForVisualTesting,
            remainingAnchorAttempts: 20
        )
    }

    private func show(
        relativeTo button: NSStatusBarButton,
        activateForVisualTesting: Bool,
        remainingAnchorAttempts: Int
    ) {
        guard let window else { return }
        anchorButton = button
        guard positionWindow() else {
            // During app launch the status button exists before AppKit has
            // attached it to its real menu-bar window. Never reveal the panel
            // at NSWindow's default bottom-left origin; wait for a valid
            // top-of-screen anchor instead.
            guard remainingAnchorAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak button] in
                guard let self, let button else { return }
                self.show(
                    relativeTo: button,
                    activateForVisualTesting: activateForVisualTesting,
                    remainingAnchorAttempts: remainingAnchorAttempts - 1
                )
            }
            return
        }
        if activateForVisualTesting {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        installEventMonitors()

        // SwiftUI reports its measured scroll height on the next update pass.
        // Re-anchor after that size arrives so the popup remains attached to
        // the status item instead of growing upward from its old origin.
        DispatchQueue.main.async { [weak self] in
            _ = self?.positionWindow()
        }
    }

    func performClose() {
        removeEventMonitors()
        window?.orderOut(nil)
    }

    private func applyPreferredContentSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            return
        }
        window?.setContentSize(size)
        if isShown {
            _ = positionWindow()
        }
    }

    @discardableResult
    private func positionWindow() -> Bool {
        guard
            let window,
            let button = anchorButton,
            let anchorWindow = button.window
        else { return false }

        let anchorInWindow = button.convert(button.bounds, to: nil)
        let anchorFrame = anchorWindow.convertToScreen(anchorInWindow)
        guard
            let screen = anchorWindow.screen
                ?? NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) }),
            anchorFrame.width > 0,
            anchorFrame.height > 0,
            anchorFrame.midY >= screen.frame.maxY - 48
        else { return false }

        let placement = MenuBarPopupPlacement.resolve(
            anchorFrame: anchorFrame,
            popupSize: window.frame.size,
            visibleFrame: screen.visibleFrame
        )
        chromeModel.arrowCenterX = placement.arrowCenterX
        window.setFrameOrigin(placement.origin)
        return true
    }

    private func installEventMonitors() {
        removeEventMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window === self.window || self.eventTargetsAnchor(event) {
                return event
            }
            self.performClose()
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.performClose()
            }
        }
    }

    private func eventTargetsAnchor(_ event: NSEvent) -> Bool {
        guard
            let button = anchorButton,
            event.window === button.window
        else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}

/// Owns everything the transparent panel has to supply in place of `NSPopover`'s
/// bezel: the beak, the shell clip and the shell rim. Keeping all three here
/// means the rim is scoped to the one surface that lacks a system frame — the
/// floating widget and the macOS 14/15 popover keep theirs.
private struct MenuBarPopupChrome<Content: View>: View {
    static var shellCornerRadius: CGFloat { 14 }

    @ObservedObject var model: MenuBarPopupChromeModel
    @ObservedObject private var preferences: PreferencesStore = .shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                MenuBarPopupArrow(
                    backdropOpacity: preferences.popoverBackgroundOpacity,
                    glassStyle: preferences.popoverGlassStyle
                )
                .frame(width: 24, height: 12)
                .position(
                    x: min(max(model.arrowCenterX, 12), proxy.size.width - 12),
                    y: 6
                )
            }
            .frame(height: 11)
            // The beak overhangs the shell by 1pt. Drawing it above the body
            // lets the two merge into one silhouette instead of stacking two
            // outlined shapes.
            .zIndex(1)

            content()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: Self.shellCornerRadius,
                        style: .continuous
                    )
                )
                .usageDockPopoverShell(
                    cornerRadius: Self.shellCornerRadius,
                    glassStyle: preferences.popoverGlassStyle
                )
        }
    }
}

private struct MenuBarPopupArrow: View {
    let backdropOpacity: Double
    let glassStyle: PopoverGlassStyle

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        ZStack {
            MenuBarPopupArrowShape()
                .fill(.ultraThinMaterial)
                .opacity(
                    glassStyle == .clear
                        ? 0
                        : UsageDockPopoverAppearance.backdropMaterialOpacity(
                            backdropOpacity: backdropOpacity
                        )
                )
            MenuBarPopupArrowShape()
                .fill(DashboardTheme.canvas.opacity(backdropOpacity))
            // The beak sits at the top of the object, where the shell rim is at
            // its specular end. Matching that single value keeps body and beak
            // reading as one continuous edge; the previous black+white pair made
            // the beak a separately drawn triangle.
            MenuBarPopupArrowOutline()
                .stroke(
                    Color.white.opacity(
                        UsageDockPopoverAppearance.shellRimHighlightOpacity(
                            glassStyle: glassStyle
                        )
                    ),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                )
        }
        .accessibilityHidden(true)
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(
                    duration: UsageDockPopoverAppearance.materialTransitionDuration
                ),
            value: glassStyle
        )
    }
}

private struct MenuBarPopupArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct MenuBarPopupArrowOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

private final class MenuBarPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
