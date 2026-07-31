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
    static var activationDistance: CGFloat { 6 }

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
            let distance = hypot(translation.width, translation.height)
            guard distance >= Self.activationDistance,
                  let sourceFrame = frames[item]
            else { return }

            let renderedOrder = candidates.filter { frames[$0] != nil }
            guard renderedOrder.contains(item) else { return }

            originalOrder = renderedOrder
            destinationIndex = renderedOrder.firstIndex(of: item)
            // Preserve the exact point where the press began. Re-anchoring when
            // the 6pt threshold is crossed would make the component jump behind
            // the pointer at activation time.
            grabOffset = CGSize(
                width: location.x - translation.width - sourceFrame.minX,
                height: location.y - translation.height - sourceFrame.minY
            )
            if case let .grid(spacing) = layout {
                rebuildGridTargetOrigins(activeItem: item, spacing: spacing)
            }
            // Publish the lift only after all captured state is ready, so the
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

    /// Visual displacement for the lifted component and every component that
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

    /// Ends the visual lift and returns the single persisted move to commit.
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

    /// Cancels only the gesture that owns the current lift. A delayed cleanup
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

/// Long-presses a component into a lifted state, then offsets the full rendered
/// component under the pointer. A short click still reaches nested controls and
/// a normal scroll remains available until the long press succeeds.
private struct DirectReorderHandleConfiguration {
    let coordinateSpace: String
    let setPressing: (Bool) -> Void
    let update: (CGPoint, CGSize) -> Void
    let finish: (CGPoint?, CGSize?) -> Void
    let cancel: () -> Void
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

/// Installs the long-press gesture only on an explicitly marked drag surface.
/// Interactive siblings such as disclosure and pin buttons therefore never
/// compete with reordering for the same pointer sequence.
private struct DirectReorderHandleModifier: ViewModifier {
    @Environment(\.directReorderHandleConfiguration) private var configuration
    @GestureState private var isGestureActive = false

    func body(content: Content) -> some View {
        if let configuration {
            content
                .contentShape(Rectangle())
                .gesture(reorderGesture(configuration))
                .onChange(of: isGestureActive) { wasActive, isActive in
                    configuration.setPressing(isActive)
                    guard wasActive, !isActive else { return }

                    // SwiftUI may cancel a gesture without delivering
                    // `onEnded` when focus changes. Clear only this handle's
                    // pending/active interaction on the next actor turn.
                    Task { @MainActor in
                        await Task.yield()
                        guard !isGestureActive else { return }
                        configuration.cancel()
                    }
                }
        } else {
            content
        }
    }

    private func reorderGesture(
        _ configuration: DirectReorderHandleConfiguration
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 12)
            .sequenced(before: DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(configuration.coordinateSpace)
            ))
            .updating($isGestureActive) { value, state, _ in
                switch value {
                case .first(true), .second(true, _):
                    state = true
                default:
                    state = false
                }
            }
            .onChanged { value in
                guard case let .second(true, dragValue) = value,
                      let dragValue
                else { return }
                configuration.update(dragValue.location, dragValue.translation)
            }
            .onEnded { value in
                if case let .second(true, dragValue) = value,
                   let dragValue {
                    configuration.finish(dragValue.location, dragValue.translation)
                } else {
                    configuration.finish(nil, nil)
                }
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
        let isPressSelected = interaction.isPressing(item) && !isDragging
        let liftPhase = isDragging ? 2 : (isPressSelected ? 1 : 0)

        ZStack {
            content
                // Keep the dragged component at its real size so the captured
                // grab point stays exactly under the pointer.
                .scaleEffect(isPressSelected ? 1.006 : 1)
                .shadow(
                    color: .black.opacity(isDragging ? 0.22 : (isPressSelected ? 0.1 : 0)),
                    radius: isDragging ? 12 : (isPressSelected ? 4 : 0),
                    y: isDragging ? 7 : (isPressSelected ? 2 : 0)
                )
                .animation(
                    reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8),
                    value: liftPhase
                )
                .offset(interaction.offset(for: item, layout: layout))
                // This is the pre-drag acknowledgement requested by the mobile
                // interaction: a completed hold lifts the whole component 3pt.
                .offset(y: isPressSelected ? (reduceMotion ? -1 : -2) : 0)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8),
                    value: isPressSelected
                )
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
        .zIndex(liftPhase > 0 ? 1_000 : 0)
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
