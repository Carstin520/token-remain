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

enum MenuBarPopupSizing {
    static let menuWidth: CGFloat = 380
    static let resizeTolerance: CGFloat = 0.5

    static func contentSize(forMenuHeight menuHeight: CGFloat) -> NSSize? {
        guard menuHeight > 0, menuHeight.isFinite else { return nil }
        return NSSize(
            width: menuWidth,
            height: menuHeight + MenuBarPopupShellShape.beakOverhang
        )
    }

    static func requiresResize(from current: NSSize, to target: NSSize) -> Bool {
        abs(current.width - target.width) >= resizeTolerance
            || abs(current.height - target.height) >= resizeTolerance
    }
}

@MainActor
private final class MenuBarPopupChromeModel: ObservableObject {
    @Published var arrowCenterX: CGFloat = 190
}

@MainActor
private final class MenuBarPopupSizeRelay {
    var onSizeChange: ((NSSize) -> Void)?

    func report(menuHeight: CGFloat) {
        guard let size = MenuBarPopupSizing.contentSize(forMenuHeight: menuHeight) else {
            return
        }
        onSizeChange?(size)
    }
}

/// macOS 26's standard NSPopover always contributes its own vibrant backdrop.
/// Host the popup in a transparent panel instead so the selected SwiftUI Glass
/// style remains the only blur/refraction source.
@MainActor
final class MenuBarPopupWindowController: NSWindowController {
    private let chromeModel: MenuBarPopupChromeModel
    private let sizeRelay: MenuBarPopupSizeRelay
    private weak var anchorButton: NSStatusBarButton?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var pendingContentSize: NSSize?
    private var contentSizeUpdateScheduled = false

    var isShown: Bool {
        window?.isVisible == true
    }

    init<Content: View>(
        @ViewBuilder rootView: @escaping (@escaping (CGFloat) -> Void) -> Content
    ) {
        let chromeModel = MenuBarPopupChromeModel()
        let sizeRelay = MenuBarPopupSizeRelay()
        self.chromeModel = chromeModel
        self.sizeRelay = sizeRelay
        let hosting = NSHostingController(
            rootView: MenuBarPopupChrome(model: chromeModel) {
                rootView { [weak sizeRelay] height in
                    sizeRelay?.report(menuHeight: height)
                }
            }
        )
        FixedHostingWindowSizing.configure(hosting)
        hosting.safeAreaRegions = []

        let initialSize = MenuBarPopupSizing.contentSize(forMenuHeight: 700)
            ?? NSSize(width: MenuBarPopupSizing.menuWidth, height: 711)

        let panel = MenuBarPopupPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
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

        sizeRelay.onSizeChange = { [weak self] size in
            self?.scheduleContentSizeUpdate(size)
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
        }
        // Always open as the key window, not merely front. macOS renders
        // Liquid Glass and materials in a flat, opaque fallback inside windows
        // it considers inactive — `orderFrontRegardless()` left the panel in
        // that state on every real status-item click, so the popup only ever
        // showed its glass in activated test runs. A nonactivating panel can
        // take key status without stealing the app-level focus.
        window.makeKeyAndOrderFront(nil)
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

    private func scheduleContentSizeUpdate(_ size: NSSize) {
        pendingContentSize = size
        guard !contentSizeUpdateScheduled else { return }
        contentSizeUpdateScheduled = true

        // Geometry changes are reported during SwiftUI layout. Move the AppKit
        // resize to the next run-loop turn so it can never synchronously re-enter
        // the layout pass that produced the measurement.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.contentSizeUpdateScheduled = false
            guard let size = self.pendingContentSize else { return }
            self.pendingContentSize = nil
            self.applyContentSize(size)
        }
    }

    private func applyContentSize(_ size: NSSize) {
        guard let window else { return }
        let currentSize = window.contentView?.bounds.size ?? window.frame.size
        guard MenuBarPopupSizing.requiresResize(from: currentSize, to: size) else {
            return
        }
        window.setContentSize(size)
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
///
/// All three are now described by a single closed path
/// (`MenuBarPopupShellShape`): backdrop, clip and rim cannot drift apart, and
/// the beak reads as part of the shell rather than a triangle stacked on top.
private struct MenuBarPopupChrome<Content: View>: View {
    @ObservedObject var model: MenuBarPopupChromeModel
    @ObservedObject private var preferences: PreferencesStore = .shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = MenuBarPopupShellShape(beakCenterX: model.arrowCenterX)
        content()
            // The shell silhouette knows about the beak; the content does not.
            // Let the chrome own the whole backdrop so the glass covers both.
            .environment(\.usageDockPopoverShellProvidesBackdrop, true)
            // The beak overhangs the shell body by 1pt, so the reserved band
            // above the content stays 11pt exactly as before.
            .padding(.top, MenuBarPopupShellShape.beakOverhang)
            .usageDockPopoverShellBackdrop(
                shape: shape,
                backdropOpacity: preferences.popoverBackgroundOpacity,
                glassStyle: preferences.popoverGlassStyle
            )
            .clipShape(shape)
            .usageDockPopoverShell(
                shape: shape,
                glassStyle: preferences.popoverGlassStyle
            )
    }
}

/// The popup's whole silhouette — shell body plus beak — as one closed path.
///
/// The beak is not a triangle sitting on the shell: its apex is rounded and
/// each side meets the shell's top edge through a tangent fillet, so the
/// outline swells out of the top edge the way a native popover's does. One
/// path serves `glassEffect(in:)`, `clipShape` and the rim `strokeBorder`,
/// which is what removes the seam and the double edge of the old two-layer
/// construction.
struct MenuBarPopupShellShape: InsettableShape {
    /// Unchanged from the two-layer chrome: shell 14 → card 13 → control 9.
    static let cornerRadius: CGFloat = 14
    static let beakWidth: CGFloat = 24
    static let beakHeight: CGFloat = 12
    /// Height of the band the beak occupies above the shell body. The beak
    /// overhangs the body by 1pt so the two overlap instead of abutting.
    static let beakOverhang: CGFloat = beakHeight - 1
    /// Flattens the apex without turning it into a dome.
    static let apexCornerRadius: CGFloat = 3.5
    /// Tangent fillet where each beak side meets the shell's top edge.
    static let junctionCornerRadius: CGFloat = 6
    /// How far the beak's footprint reaches into the shell body. Only ever
    /// consumed by the union below, never visible.
    private static let beakRootDepth: CGFloat = 8

    var beakCenterX: CGFloat
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> MenuBarPopupShellShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let shellRect = CGRect(
            x: rect.minX + inset,
            y: rect.minY + Self.beakOverhang + inset,
            width: rect.width - (inset * 2),
            height: rect.height - Self.beakOverhang - (inset * 2)
        )
        let radius = max(Self.cornerRadius - inset, 0)
        let body = Path(
            roundedRect: shellRect,
            cornerSize: CGSize(width: radius, height: radius),
            style: .continuous
        )
        guard
            shellRect.width > (Self.cornerRadius * 2),
            shellRect.height > Self.beakRootDepth,
            let beak = beakPath(in: rect, shellRect: shellRect)
        else { return body }
        return body.union(beak)
    }

    /// A closed region containing the beak plus a shallow root inside the shell
    /// body, so the union with the body leaves only the beak's outer contour.
    private func beakPath(in rect: CGRect, shellRect: CGRect) -> Path? {
        let topEdgeY = shellRect.minY
        // 24 × 12 puts both sides at 45°, so the beak's half-width at any
        // height is that height times this slope.
        let slope = (Self.beakWidth / 2) / Self.beakHeight
        // Insetting a corner moves its apex along the bisector by
        // inset / sin(half-angle).
        let apexY = rect.minY + (inset * sqrt(1 + (slope * slope)) / slope)
        let halfSpanAtTopEdge = (topEdgeY - apexY) * slope
        guard halfSpanAtTopEdge > 0 else { return nil }

        let junctionRadius = Self.junctionCornerRadius + inset
        let apexRadius = max(Self.apexCornerRadius - inset, 0)
        // Where the beak's footprint on the top edge ends. Generous: the run
        // beyond the fillet's tangent point is collinear with the shell's own
        // top edge, so the union discards it.
        let halfFootprint = halfSpanAtTopEdge + junctionRadius

        // `MenuBarPopupPlacement` still decides where the beak points; this only
        // keeps its footprint off the shell's rounded corners, where a merged
        // silhouette would grow a bump on the side instead of a crest on top.
        // It engages nowhere a real status item can sit — a 380pt-wide popup
        // would have to be clamped against a screen edge with the status item
        // within 31pt of it — and only at positions where the old sharp
        // triangle was already being drawn across a corner.
        let clearance = Self.cornerRadius + halfFootprint
        let centerX = min(
            max(beakCenterX, shellRect.minX + clearance),
            shellRect.maxX - clearance
        )

        let apex = CGPoint(x: centerX, y: apexY)
        let leftJunction = CGPoint(x: centerX - halfSpanAtTopEdge, y: topEdgeY)
        let rightJunction = CGPoint(x: centerX + halfSpanAtTopEdge, y: topEdgeY)
        let rootLeft = CGPoint(x: centerX - halfFootprint, y: topEdgeY)
        let rootRight = CGPoint(x: centerX + halfFootprint, y: topEdgeY)
        let rootY = topEdgeY + Self.beakRootDepth

        var path = Path()
        path.move(to: rootLeft)
        path.addArc(tangent1End: leftJunction, tangent2End: apex, radius: junctionRadius)
        path.addArc(tangent1End: apex, tangent2End: rightJunction, radius: apexRadius)
        path.addArc(tangent1End: rightJunction, tangent2End: rootRight, radius: junctionRadius)
        path.addLine(to: rootRight)
        path.addLine(to: CGPoint(x: rootRight.x, y: rootY))
        path.addLine(to: CGPoint(x: rootLeft.x, y: rootY))
        path.closeSubpath()
        return path
    }
}

private final class MenuBarPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
