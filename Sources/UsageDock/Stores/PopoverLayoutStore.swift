import Combine
import Foundation

enum PopoverWidget: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex
    case localUsage
    case aiFeed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .localUsage: return L10n.text("widget.local_usage")
        case .aiFeed: return L10n.text("widget.ai_feed")
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "circle.hexagongrid"
        case .localUsage: return "chart.donut"
        case .aiFeed: return "newspaper"
        }
    }

    var supportsExpansion: Bool {
        self != .localUsage
    }
}

/// Owns the menu popover's widget order and durable preferences.
///
/// Expansion is intentionally session-scoped unless a widget is pinned. This
/// gives "保持展开" one clear meaning: pinned widgets reopen expanded, while
/// ordinary exploration resets to the compact state the next time the popover
/// is presented.
final class PopoverLayoutStore: ObservableObject {
    static let defaultsKey = "tokenRemain.popoverLayout.v1"
    static let defaultOrder: [PopoverWidget] = [.claude, .codex, .localUsage, .aiFeed]

    @Published private(set) var order: [PopoverWidget]
    @Published private(set) var hiddenWidgets: Set<PopoverWidget>
    @Published private(set) var pinnedWidgets: Set<PopoverWidget>
    @Published private(set) var expandedWidgets: Set<PopoverWidget>

    private let defaults: UserDefaults

    var visibleWidgets: [PopoverWidget] {
        order.filter { !hiddenWidgets.contains($0) }
    }

    var availableWidgets: [PopoverWidget] {
        Self.defaultOrder.filter(hiddenWidgets.contains)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let persisted = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(PersistedLayout.self, from: $0) }

        let loadedPinned = Set((persisted?.pinned ?? []).compactMap(PopoverWidget.init(rawValue:)))
            .intersection(Set(Self.defaultOrder.filter(\.supportsExpansion)))
        order = Self.mergedOrder(persisted?.order ?? [])
        hiddenWidgets = Set((persisted?.hidden ?? []).compactMap(PopoverWidget.init(rawValue:)))
        pinnedWidgets = loadedPinned
        expandedWidgets = loadedPinned
    }

    func prepareForPresentation() {
        expandedWidgets = pinnedWidgets
    }

    func isExpanded(_ widget: PopoverWidget) -> Bool {
        expandedWidgets.contains(widget) || pinnedWidgets.contains(widget)
    }

    func isPinned(_ widget: PopoverWidget) -> Bool {
        pinnedWidgets.contains(widget)
    }

    func toggleExpanded(_ widget: PopoverWidget) {
        guard widget.supportsExpansion else { return }
        if isExpanded(widget) {
            // Collapsing. A pinned widget is expanded *because* it is pinned, so
            // collapsing it also releases the pin in one action — no blocking
            // "unpin first" prompt. The unpin is durable, hence save().
            if pinnedWidgets.contains(widget) {
                pinnedWidgets.remove(widget)
                save()
            }
            expandedWidgets.remove(widget)
        } else {
            expandedWidgets.insert(widget)
        }
    }

    func togglePinned(_ widget: PopoverWidget) {
        guard widget.supportsExpansion else { return }
        if pinnedWidgets.contains(widget) {
            pinnedWidgets.remove(widget)
        } else {
            pinnedWidgets.insert(widget)
            expandedWidgets.insert(widget)
        }
        save()
    }

    func hide(_ widget: PopoverWidget) {
        hiddenWidgets.insert(widget)
        expandedWidgets.remove(widget)
        save()
    }

    func show(_ widget: PopoverWidget) {
        if !order.contains(widget) {
            order.append(widget)
        }
        hiddenWidgets.remove(widget)
        if pinnedWidgets.contains(widget) {
            expandedWidgets.insert(widget)
        }
        save()
    }

    func move(_ widget: PopoverWidget, before destination: PopoverWidget) {
        guard widget != destination,
              order.contains(widget),
              order.contains(destination)
        else { return }

        order.removeAll { $0 == widget }
        guard let destinationIndex = order.firstIndex(of: destination) else { return }
        order.insert(widget, at: destinationIndex)
        save()
    }

    func moveUp(_ widget: PopoverWidget) {
        let visible = visibleWidgets
        guard let index = visible.firstIndex(of: widget), index > 0 else { return }
        move(widget, before: visible[index - 1])
    }

    func moveDown(_ widget: PopoverWidget) {
        let visible = visibleWidgets
        guard let index = visible.firstIndex(of: widget), index + 1 < visible.count else { return }
        let next = visible[index + 1]
        order.removeAll { $0 == widget }
        guard let nextIndex = order.firstIndex(of: next) else { return }
        order.insert(widget, at: min(nextIndex + 1, order.count))
        save()
    }

    private func save() {
        let payload = PersistedLayout(
            order: order.map(\.rawValue),
            hidden: Self.defaultOrder.filter(hiddenWidgets.contains).map(\.rawValue),
            pinned: Self.defaultOrder.filter(pinnedWidgets.contains).map(\.rawValue)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func mergedOrder(_ rawOrder: [String]) -> [PopoverWidget] {
        var seen = Set<PopoverWidget>()
        let known = rawOrder.compactMap(PopoverWidget.init(rawValue:)).filter { seen.insert($0).inserted }
        return known + defaultOrder.filter { !seen.contains($0) }
    }

    private struct PersistedLayout: Codable {
        let order: [String]
        let hidden: [String]
        let pinned: [String]
    }
}
