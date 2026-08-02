import AppKit
import Observation
import SwiftUI

/// The layout being rearranged. The menu-bar popover is a single vertical
/// stack, while Dashboard Limits uses an adaptive multi-column grid.
enum DirectReorderLayout {
    case vertical(spacing: CGFloat)
    case grid(spacing: CGFloat)
}

/// Coordinates direct manipulation without changing the persisted order until
/// the pointer is released.
///
/// SwiftUI's system drag APIs leave the source in place and render a separate
/// preview. This coordinator instead offsets the rendered component itself,
/// keeps the initial grab point under the pointer, and gives neighboring
/// components temporary vacancy offsets while a drag is active.
@MainActor
@Observable
final class DirectReorderInteraction<Item: Hashable> {
    private(set) var activeItem: Item?
    private(set) var pressedItem: Item?
    private(set) var pointerLocation: CGPoint?
    private(set) var relocationFeedback = 0

    // Geometry changes are inputs to a future drag, not UI state by themselves.
    // Keeping them out of Observation prevents a card measurement from
    // invalidating every card that reads an offset from this interaction.
    @ObservationIgnored private var frames: [Item: CGRect] = [:]
    @ObservationIgnored private var grabOffset = CGSize.zero
    @ObservationIgnored private var acceptsDrop = false
    @ObservationIgnored private var cachedGridTargetOrigins: [Item: CGPoint] = [:]

    private var originalOrder: [Item] = []
    private var destinationIndex: Int?

    var isActive: Bool { activeItem != nil }

    func updateFrame(_ frame: CGRect, for item: Item) {
        // A lifted card and its neighbors are visually transformed. Depending
        // on the hosting hierarchy, geometry callbacks can observe those
        // presentation positions while the spring is running. Feeding them
        // back into `frames` makes the next pointer sample chase an animated
        // layout and can create an expensive measurement/offset feedback loop.
        // Keep the captured slots immutable for the lifetime of a drag.
        guard activeItem == nil else { return }
        guard frames[item] != frame else { return }
        frames[item] = frame
    }

    func removeFrame(for item: Item) {
        frames.removeValue(forKey: item)
        if activeItem == item {
            cancel()
        }
    }

    func isDragging(_ item: Item) -> Bool {
        activeItem == item
    }

    func isPressing(_ item: Item) -> Bool {
        pressedItem == item
    }

    func setPressing(_ pressing: Bool, item: Item) {
        if pressing {
            guard activeItem == nil,
                  pressedItem == nil || pressedItem == item
            else { return }
            pressedItem = item
        } else if pressedItem == item {
            pressedItem = nil
        }
    }

    func update(
        item: Item,
        location: CGPoint,
        translation: CGSize,
        candidates: [Item],
        layout: DirectReorderLayout
    ) {
        if activeItem == nil {
            guard let sourceFrame = frames[item] else { return }

            let renderedOrder = candidates.filter { frames[$0] != nil }
            guard renderedOrder.contains(item) else { return }

            originalOrder = renderedOrder
            destinationIndex = renderedOrder.firstIndex(of: item)
            // Preserve the exact point where the drag phase began. The long
            // press is the only activation threshold, so even the first subtle
            // pointer movement moves the rendered component without a second
            // selection stage or a jump behind the pointer.
            grabOffset = CGSize(
                width: location.x - translation.width - sourceFrame.minX,
                height: location.y - translation.height - sourceFrame.minY
            )
            if case let .grid(spacing) = layout {
                rebuildGridTargetOrigins(activeItem: item, spacing: spacing)
            }
            // Publish the drag only after all captured state is ready, so the
            // first rendered drag frame never observes a half-initialized move.
            activeItem = item
        }

        guard activeItem == item else { return }
        if pointerLocation != location {
            // With field-granular Observation, only the active card reads this
            // value. Pointer samples no longer rebuild the whole grid/popover.
            pointerLocation = location
        }
        updateDestination(for: item, location: location, layout: layout)
    }

    /// Visual displacement for the dragged component and every component that
    /// temporarily fills its vacancy.
    func offset(for item: Item, layout: DirectReorderLayout) -> CGSize {
        guard let activeItem,
              let sourceIndex = originalOrder.firstIndex(of: activeItem),
              let destinationIndex,
              let sourceFrame = frames[activeItem]
        else { return .zero }

        if item == activeItem {
            guard let pointerLocation else { return .zero }
            return CGSize(
                width: pointerLocation.x - grabOffset.width - sourceFrame.minX,
                height: pointerLocation.y - grabOffset.height - sourceFrame.minY
            )
        }

        guard let itemIndex = originalOrder.firstIndex(of: item),
              let itemFrame = frames[item]
        else { return .zero }

        switch layout {
        case let .vertical(spacing):
            let sourceSlotHeight = sourceFrame.height + spacing
            if sourceIndex < destinationIndex,
               itemIndex > sourceIndex,
               itemIndex <= destinationIndex {
                return CGSize(width: 0, height: -sourceSlotHeight)
            }
            if destinationIndex < sourceIndex,
               itemIndex >= destinationIndex,
               itemIndex < sourceIndex {
                return CGSize(width: 0, height: sourceSlotHeight)
            }
            return .zero

        case .grid:
            guard let targetOrigin = cachedGridTargetOrigins[item] else {
                return .zero
            }
            return CGSize(
                width: targetOrigin.x - itemFrame.minX,
                height: targetOrigin.y - itemFrame.minY
            )
        }
    }

    /// Ends the direct manipulation and returns the single persisted move to commit.
    func finish(item endingItem: Item) -> (item: Item, target: Item)? {
        guard activeItem == endingItem else { return nil }
        let move = activeItem.flatMap { item -> (item: Item, target: Item)? in
            guard acceptsDrop,
                  let sourceIndex = originalOrder.firstIndex(of: item),
                  let destinationIndex,
                  destinationIndex != sourceIndex
            else { return nil }
            return (item: item, target: originalOrder[destinationIndex])
        }
        reset()
        return move
    }

    /// Cancels only the gesture that owns the current drag. A delayed cleanup
    /// from an older view must never tear down a newer component's drag.
    func cancel(item: Item) {
        guard activeItem == item else { return }
        reset()
    }

    func cancel() {
        reset()
    }

    private func reset() {
        activeItem = nil
        pressedItem = nil
        pointerLocation = nil
        grabOffset = .zero
        originalOrder = []
        destinationIndex = nil
        acceptsDrop = false
        cachedGridTargetOrigins = [:]
    }

    private func updateDestination(
        for item: Item,
        location: CGPoint,
        layout: DirectReorderLayout
    ) {
        guard let sourceIndex = originalOrder.firstIndex(of: item),
              let sourceFrame = frames[item]
        else { return }

        let availableFrames = originalOrder.compactMap { frames[$0] }
        let bounds = availableFrames.reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -44, dy: -60)
        acceptsDrop = bounds.contains(location)

        var nextIndex = sourceIndex
        if acceptsDrop {
            switch layout {
            case .vertical:
                // Match the mobile interaction: the moving component's leading
                // or trailing edge crossing a neighbor's center advances the
                // vacancy. This stays predictable when card heights differ.
                let liftedMinY = location.y - grabOffset.height
                let liftedMaxY = liftedMinY + sourceFrame.height
                if liftedMaxY > sourceFrame.maxY {
                    for index in originalOrder.indices where index > sourceIndex {
                        guard let frame = frames[originalOrder[index]] else { continue }
                        if liftedMaxY >= frame.midY { nextIndex = index }
                    }
                } else if liftedMinY < sourceFrame.minY {
                    for index in originalOrder.indices.reversed() where index < sourceIndex {
                        guard let frame = frames[originalOrder[index]] else { continue }
                        if liftedMinY <= frame.midY { nextIndex = index }
                    }
                }

            case .grid:
                // In a two-dimensional grid, the nearest card center is the
                // stable equivalent of crossing a vertical neighbor's center.
                nextIndex = originalOrder.indices.min { lhs, rhs in
                    normalizedDistance(from: location, to: frames[originalOrder[lhs]])
                        < normalizedDistance(from: location, to: frames[originalOrder[rhs]])
                } ?? sourceIndex
            }
        }

        guard destinationIndex != nextIndex else { return }
        destinationIndex = nextIndex
        if case let .grid(spacing) = layout {
            // Reflow once per destination change. Previously every card rebuilt
            // this dictionary for every pointer sample, producing quadratic
            // allocation and layout work while crossing the grid.
            rebuildGridTargetOrigins(activeItem: item, spacing: spacing)
        }
        relocationFeedback += 1
    }

    private func normalizedDistance(from point: CGPoint, to frame: CGRect?) -> CGFloat {
        guard let frame else { return .greatestFiniteMagnitude }
        let dx = (point.x - frame.midX) / max(frame.width, 1)
        let dy = (point.y - frame.midY) / max(frame.height, 1)
        return hypot(dx, dy)
    }

    /// Reflows the captured grid using the real column origins and card heights,
    /// so multi-row neighbors visibly occupy their future slots before drop.
    private func rebuildGridTargetOrigins(activeItem: Item, spacing: CGFloat) {
        guard let destinationIndex,
              let sourceIndex = originalOrder.firstIndex(of: activeItem)
        else {
            cachedGridTargetOrigins = [:]
            return
        }

        let availableFrames = originalOrder.compactMap { frames[$0] }
        guard !availableFrames.isEmpty else {
            cachedGridTargetOrigins = [:]
            return
        }

        let columnOrigins = availableFrames
            .map(\.minX)
            .sorted()
            .reduce(into: [CGFloat]()) { origins, value in
                if origins.last.map({ abs($0 - value) > 2 }) ?? true {
                    origins.append(value)
                }
            }
        guard !columnOrigins.isEmpty else {
            cachedGridTargetOrigins = [:]
            return
        }

        var previewOrder = originalOrder
        let lifted = previewOrder.remove(at: sourceIndex)
        previewOrder.insert(lifted, at: min(destinationIndex, previewOrder.count))

        var origins: [Item: CGPoint] = [:]
        var rowY = availableFrames.map(\.minY).min() ?? 0
        let columnCount = columnOrigins.count

        for rowStart in stride(from: 0, to: previewOrder.count, by: columnCount) {
            let rowEnd = min(rowStart + columnCount, previewOrder.count)
            let rowItems = Array(previewOrder[rowStart..<rowEnd])
            var rowHeight: CGFloat = 0

            for (column, item) in rowItems.enumerated() {
                guard let frame = frames[item] else { continue }
                origins[item] = CGPoint(x: columnOrigins[column], y: rowY)
                rowHeight = max(rowHeight, frame.height)
            }
            rowY += rowHeight + spacing
        }

        cachedGridTargetOrigins = origins
    }
}

/// Selects a component after one long-press threshold, then offsets the full
/// rendered component under the pointer. A short click still reaches nested
/// controls and a normal scroll remains available until the long press succeeds.
private struct DirectReorderHandleConfiguration {
    let coordinateSpace: String
    let setPressing: (Bool) -> Void
    let update: (CGPoint, CGSize) -> Void
    let finish: (CGPoint?, CGSize?) -> Void
    let cancel: () -> Void
}

/// Maps pointer samples from a fixed AppKit coordinate space into SwiftUI's
/// reorder space. The fixed-space origin never moves with the dragged view, so
/// rendering an offset cannot feed back into the next pointer sample.
struct DirectReorderPointerAnchor {
    let stableLocation: CGPoint
    let reorderLocation: CGPoint

    func sample(at currentStableLocation: CGPoint) -> (location: CGPoint, translation: CGSize) {
        let translation = CGSize(
            width: currentStableLocation.x - stableLocation.x,
            height: currentStableLocation.y - stableLocation.y
        )
        return (
            CGPoint(
                x: reorderLocation.x + translation.width,
                y: reorderLocation.y + translation.height
            ),
            translation
        )
    }
}

private struct DirectReorderHandleConfigurationKey: EnvironmentKey {
    static let defaultValue: DirectReorderHandleConfiguration? = nil
}

private extension EnvironmentValues {
    var directReorderHandleConfiguration: DirectReorderHandleConfiguration? {
        get { self[DirectReorderHandleConfigurationKey.self] }
        set { self[DirectReorderHandleConfigurationKey.self] = newValue }
    }
}

/// Installs one reusable AppKit press recognizer without taking over SwiftUI's
/// rendering or reorder state. `NSPressGestureRecognizer` resets itself to
/// `.possible` after every completed/cancelled sequence, unlike the sequenced
/// SwiftUI gesture that could stop rearming after its view moved in a ScrollView.
private struct DirectReorderPressBridge: NSViewRepresentable {
    let configuration: DirectReorderHandleConfiguration
    let handleFrame: CGRect

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration, handleFrame: handleFrame)
    }

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        context.coordinator.installerView = view
        return view
    }

    func updateNSView(_ nsView: InstallerView, context: Context) {
        context.coordinator.configuration = configuration
        context.coordinator.handleFrame = handleFrame
        context.coordinator.install(on: nsView.window?.contentView)
    }

    static func dismantleNSView(_ nsView: InstallerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class InstallerView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.install(on: window?.contentView)
        }

        // The bridge only installs a recognizer on the window content view.
        // Keeping the probe out of hit testing preserves text, buttons, and
        // context menus while the delegate restricts recognition to our bounds.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var configuration: DirectReorderHandleConfiguration
        var handleFrame: CGRect
        weak var installerView: InstallerView?
        weak var installedView: NSView?
        private var pendingAnchor: DirectReorderPointerAnchor?
        private var activeAnchor: DirectReorderPointerAnchor?
        private var mouseUpFallbackMonitor: Any?

        private lazy var recognizer: NSPressGestureRecognizer = {
            let recognizer = NSPressGestureRecognizer(
                target: self,
                action: #selector(handlePress(_:))
            )
            // A trackpad press naturally drifts before selection. Use a short
            // acknowledgement window and a generous slop area instead of
            // requiring the pointer to remain almost stationary.
            recognizer.minimumPressDuration = 0.18
            recognizer.allowableMovement = 36
            recognizer.buttonMask = 0x1
            recognizer.delegate = self
            return recognizer
        }()

        init(
            configuration: DirectReorderHandleConfiguration,
            handleFrame: CGRect
        ) {
            self.configuration = configuration
            self.handleFrame = handleFrame
        }

        func install(on view: NSView?) {
            guard let view, installedView !== view else { return }
            // Moving this bridge to another window while a press is active is
            // an interruption, not a continuation: the fixed pointer anchor
            // belongs to the old content view. Always release shared reorder
            // state before installing on the replacement view.
            detach()
            installedView = view
            view.addGestureRecognizer(recognizer)
        }

        func detach() {
            cancelActiveSequence()
            installedView?.removeGestureRecognizer(recognizer)
            installedView = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            pendingAnchor = nil
            guard let installerView, installedView != nil else { return false }
            let location = installerView.convert(event.locationInWindow, from: nil)
            guard installerView.bounds.contains(location) else { return false }
            pendingAnchor = DirectReorderPointerAnchor(
                stableLocation: stablePointerLocation(for: event),
                reorderLocation: locationInReorderSpace(local: location)
            )
            return true
        }

        @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                let anchor = pendingAnchor ?? fallbackAnchor(for: recognizer)
                activeAnchor = anchor
                beginInterruptionFallbacks()
                let sample = anchor.sample(at: stablePointerLocation(for: recognizer))
                configuration.setPressing(true)
                // Preserve any natural trackpad slide that happened during the
                // selection window. The component catches up from the original
                // grab point on this first selected frame, then follows without
                // another threshold.
                configuration.update(sample.location, sample.translation)

            case .changed:
                guard let activeAnchor else { return }
                let sample = activeAnchor.sample(at: stablePointerLocation(for: recognizer))
                configuration.update(sample.location, sample.translation)

            case .ended:
                guard let activeAnchor else {
                    cancelActiveSequence()
                    return
                }
                let sample = activeAnchor.sample(at: stablePointerLocation(for: recognizer))
                configuration.finish(sample.location, sample.translation)
                self.activeAnchor = nil
                pendingAnchor = nil
                endInterruptionFallbacks()

            case .cancelled:
                cancelActiveSequence()

            case .failed:
                // AppKit can fail a recognizer when its view/window changes
                // mid-sequence. Treat that exactly like cancellation so the
                // shared interaction cannot remain permanently active.
                cancelActiveSequence()

            case .possible:
                break

            @unknown default:
                cancelActiveSequence()
            }
        }

        /// AppKit normally delivers `.ended` or `.cancelled`, but mouse-up can
        /// be lost when a window resigns key status, the app deactivates, or a
        /// SwiftUI hierarchy is replaced during a press. Those interruption
        /// paths previously left `DirectReorderInteraction.activeItem` set,
        /// making scrolling and later drags appear frozen until relaunch.
        private func beginInterruptionFallbacks() {
            endInterruptionFallbacks()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePressInterruption(_:)),
                name: NSApplication.didResignActiveNotification,
                object: NSApp
            )
            if let window = installedView?.window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handlePressInterruption(_:)),
                    name: NSWindow.didResignKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handlePressInterruption(_:)),
                    name: NSWindow.willCloseNotification,
                    object: window
                )
            }

            // Run after AppKit has offered the mouse-up to the recognizer. A
            // normal `.ended` clears `activeAnchor`; this block only repairs a
            // missing terminal callback while the app remains active.
            mouseUpFallbackMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseUp
            ) { [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    guard self?.activeAnchor != nil else { return }
                    self?.cancelActiveSequence()
                }
                return event
            }
        }

        private func endInterruptionFallbacks() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didResignActiveNotification,
                object: NSApp
            )
            if let window = installedView?.window {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didResignKeyNotification,
                    object: window
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: window
                )
            }
            if let mouseUpFallbackMonitor {
                NSEvent.removeMonitor(mouseUpFallbackMonitor)
                self.mouseUpFallbackMonitor = nil
            }
        }

        @objc private func handlePressInterruption(_ notification: Notification) {
            cancelActiveSequence()
        }

        private func cancelActiveSequence() {
            // Cancellation is item-scoped by DirectReorderInteraction, so it
            // is safe to release this handle even if AppKit already discarded
            // its anchor. This closes the exact orphaned-state path where the
            // recognizer failed first and SwiftUI dismantled the bridge later.
            configuration.setPressing(false)
            configuration.cancel()
            activeAnchor = nil
            pendingAnchor = nil
            endInterruptionFallbacks()
        }

        private func fallbackAnchor(
            for recognizer: NSPressGestureRecognizer
        ) -> DirectReorderPointerAnchor {
            DirectReorderPointerAnchor(
                stableLocation: stablePointerLocation(for: recognizer),
                // This fallback is sampled only before the component receives
                // its first offset, so the installer view is still stationary.
                reorderLocation: locationInReorderSpace(for: recognizer)
            )
        }

        private func stablePointerLocation(for event: NSEvent) -> CGPoint {
            guard let installedView else { return event.locationInWindow }
            return topLeadingPoint(
                installedView.convert(event.locationInWindow, from: nil),
                in: installedView
            )
        }

        private func stablePointerLocation(
            for recognizer: NSPressGestureRecognizer
        ) -> CGPoint {
            guard let installedView else { return recognizer.location(in: nil) }
            return topLeadingPoint(recognizer.location(in: installedView), in: installedView)
        }

        private func topLeadingPoint(_ point: CGPoint, in view: NSView) -> CGPoint {
            CGPoint(
                x: point.x,
                y: view.isFlipped ? point.y : view.bounds.height - point.y
            )
        }

        private func locationInReorderSpace(
            for recognizer: NSPressGestureRecognizer
        ) -> CGPoint {
            guard let installerView else { return handleFrame.origin }
            return locationInReorderSpace(local: recognizer.location(in: installerView))
        }

        private func locationInReorderSpace(local: CGPoint) -> CGPoint {
            guard let installerView else { return handleFrame.origin }
            let localY = installerView.isFlipped
                ? local.y
                : installerView.bounds.height - local.y
            return CGPoint(
                x: handleFrame.minX + local.x,
                y: handleFrame.minY + localY
            )
        }
    }
}

/// Installs the long-press gesture only on an explicitly marked drag surface.
/// Interactive siblings such as disclosure and pin buttons therefore never
/// compete with reordering for the same pointer sequence.
private struct DirectReorderHandleModifier: ViewModifier {
    @Environment(\.directReorderHandleConfiguration) private var configuration
    @State private var handleFrame = CGRect.zero

    func body(content: Content) -> some View {
        if let configuration {
            content
                .contentShape(Rectangle())
                .background {
                    DirectReorderPressBridge(
                        configuration: configuration,
                        handleFrame: handleFrame
                    )
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(configuration.coordinateSpace))
                } action: { frame in
                    handleFrame = frame
                }
        } else {
            content
        }
    }
}

private struct DirectReorderModifier<Item: Hashable>: ViewModifier {
    let item: Item
    let candidates: [Item]
    let coordinateSpace: String
    let interaction: DirectReorderInteraction<Item>
    let layout: DirectReorderLayout
    let move: (Item, Item) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let isDragging = interaction.isDragging(item)
        let isSelected = interaction.isPressing(item) || isDragging

        ZStack {
            content
                // A single static outline acknowledges the completed hold.
                // It intentionally does not flash, scale, lift, or animate.
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            DashboardTheme.violet.opacity(isSelected ? 0.72 : 0),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                }
                // Keep the dragged component at its real size and move the
                // rendered view itself, preserving the original grab point.
                .offset(interaction.offset(for: item, layout: layout))
                // Pointer movement is unanimated. Only neighbors spring when
                // the vacancy advances to a different component.
                .animation(
                    isDragging || reduceMotion
                        ? nil
                        : .spring(response: 0.28, dampingFraction: 0.82),
                    value: interaction.relocationFeedback
                )
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(coordinateSpace))
        } action: { frame in
            interaction.updateFrame(frame, for: item)
        }
        .onDisappear {
            interaction.removeFrame(for: item)
        }
        .zIndex(isSelected ? 1_000 : 0)
        .environment(\.directReorderHandleConfiguration, handleConfiguration)
    }

    private var handleConfiguration: DirectReorderHandleConfiguration {
        DirectReorderHandleConfiguration(
            coordinateSpace: coordinateSpace,
            setPressing: { pressing in
                interaction.setPressing(pressing, item: item)
            },
            update: { location, translation in
                interaction.update(
                    item: item,
                    location: location,
                    translation: translation,
                    candidates: candidates,
                    layout: layout
                )
            },
            finish: { location, translation in
                if let location, let translation {
                    interaction.update(
                        item: item,
                        location: location,
                        translation: translation,
                        candidates: candidates,
                        layout: layout
                    )
                }
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.84)) {
                    if interaction.isDragging(item),
                       let destination = interaction.finish(item: item) {
                        move(destination.item, destination.target)
                    } else if interaction.isDragging(item) {
                        interaction.cancel(item: item)
                    }
                }
                interaction.setPressing(false, item: item)
            },
            cancel: {
                interaction.setPressing(false, item: item)
                interaction.cancel(item: item)
            }
        )
    }
}

extension View {
    /// Marks a precise hit region as draggable. Use this on non-control header
    /// surfaces; disclosure, pin, and content controls remain outside it.
    func directReorderHandle() -> some View {
        modifier(DirectReorderHandleModifier())
    }

    func directReorder<Item: Hashable>(
        item: Item,
        candidates: [Item],
        coordinateSpace: String,
        interaction: DirectReorderInteraction<Item>,
        layout: DirectReorderLayout,
        move: @escaping (Item, Item) -> Void
    ) -> some View {
        modifier(DirectReorderModifier(
            item: item,
            candidates: candidates,
            coordinateSpace: coordinateSpace,
            interaction: interaction,
            layout: layout,
            move: move
        ))
    }
}
