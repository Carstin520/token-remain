import Foundation
import Observation
import TokenRemainKit

/// The iPhone counterpart to the Mac Dock layout. This state is intentionally
/// local: changing a card's order, visibility, or disclosure state changes only
/// this device's presentation and is never written to the encrypted sync record.
@MainActor
@Observable
final class OverviewLayoutStore {
    enum Widget: String, CaseIterable, Codable, Identifiable {
        case claude
        case codex
        case todayUsage
        case reset
        case curatedFeed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claude: return ProviderQuota.Provider.claude.shortName
            case .codex: return ProviderQuota.Provider.codex.shortName
            case .todayUsage: return TRL10n.t("today.title")
            case .reset: return TRL10n.t("overview.reset.card")
            case .curatedFeed: return TRL10n.t("overview.feed.title")
            }
        }

        var systemImage: String {
            switch self {
            case .claude: return "sparkles"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .todayUsage: return "chart.pie"
            case .reset: return "timer"
            case .curatedFeed: return "bubble.left.and.bubble.right"
            }
        }

        var provider: ProviderQuota.Provider? {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            case .todayUsage, .reset, .curatedFeed: return nil
            }
        }
    }

    private enum Key {
        static let order = "tokenremain.overview.widget-order.v1"
        static let hidden = "tokenremain.overview.hidden-widgets.v1"
        static let expanded = "tokenremain.overview.expanded-providers.v1"
    }

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var orderedWidgets: [Widget]
    private(set) var hiddenWidgets: Set<Widget>
    private(set) var expandedProviders: Set<ProviderQuota.Provider>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if ProcessInfo.processInfo.arguments.contains("-tr-reset-overview-layout") {
            defaults.removeObject(forKey: Key.order)
            defaults.removeObject(forKey: Key.hidden)
            defaults.removeObject(forKey: Key.expanded)
        }
        orderedWidgets = Self.readWidgets(for: Key.order, defaults: defaults)
        // Hidden state is an exact set, not an order. Reusing `readWidgets`
        // here would append every missing default and hide all cards on a fresh
        // install.
        hiddenWidgets = Set(
            defaults.stringArray(forKey: Key.hidden)?.compactMap(Widget.init(rawValue:)) ?? []
        )
        expandedProviders = Set(
            defaults.stringArray(forKey: Key.expanded)?.compactMap(ProviderQuota.Provider.init(rawValue:)) ?? []
        )
    }

    var visibleWidgets: [Widget] {
        orderedWidgets.filter { !hiddenWidgets.contains($0) }
    }

    var availableWidgets: [Widget] {
        orderedWidgets.filter(hiddenWidgets.contains)
    }

    func isExpanded(_ provider: ProviderQuota.Provider) -> Bool {
        expandedProviders.contains(provider)
    }

    func toggleExpanded(_ provider: ProviderQuota.Provider) {
        if expandedProviders.contains(provider) {
            expandedProviders.remove(provider)
        } else {
            expandedProviders.insert(provider)
        }
        persistExpandedProviders()
    }

    func show(_ widget: Widget) {
        hiddenWidgets.remove(widget)
        persistWidgets()
    }

    func hide(_ widget: Widget) {
        guard visibleWidgets.count > 1 else { return }
        hiddenWidgets.insert(widget)
        persistWidgets()
    }

    func moveUp(_ widget: Widget) {
        let visible = visibleWidgets
        guard let index = visible.firstIndex(of: widget), index > 0,
              let sourceIndex = orderedWidgets.firstIndex(of: widget),
              let targetIndex = orderedWidgets.firstIndex(of: visible[index - 1]) else { return }
        orderedWidgets.swapAt(sourceIndex, targetIndex)
        persistWidgets()
    }

    func moveDown(_ widget: Widget) {
        let visible = visibleWidgets
        guard let index = visible.firstIndex(of: widget), index < visible.count - 1,
              let sourceIndex = orderedWidgets.firstIndex(of: widget),
              let targetIndex = orderedWidgets.firstIndex(of: visible[index + 1]) else { return }
        orderedWidgets.swapAt(sourceIndex, targetIndex)
        persistWidgets()
    }

    func canMoveUp(_ widget: Widget) -> Bool {
        visibleWidgets.firstIndex(of: widget).map { $0 > 0 } ?? false
    }

    func canMoveDown(_ widget: Widget) -> Bool {
        visibleWidgets.firstIndex(of: widget).map { $0 < visibleWidgets.count - 1 } ?? false
    }

    private func persistWidgets() {
        defaults.set(orderedWidgets.map(\.rawValue), forKey: Key.order)
        defaults.set(hiddenWidgets.map(\.rawValue), forKey: Key.hidden)
    }

    private func persistExpandedProviders() {
        defaults.set(expandedProviders.map(\.rawValue), forKey: Key.expanded)
    }

    private static func readWidgets(for key: String, defaults: UserDefaults) -> [Widget] {
        let decoded = defaults.stringArray(forKey: key)?.compactMap(Widget.init(rawValue:)) ?? []
        let unique = decoded.reduce(into: [Widget]()) { result, widget in
            if !result.contains(widget) { result.append(widget) }
        }
        return unique + Widget.allCases.filter { !unique.contains($0) }
    }
}
