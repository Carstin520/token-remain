import Combine
import Foundation

enum PopoverWidget: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex
    case cursor
    case grok
    case zai
    case copilot
    case devin
    case openrouter
    case antigravity
    case opencode
    case deepseek
    case kimi
    case minimax
    case mimo
    case qoder
    case kiro
    case volcengine
    case ollama
    case localUsage
    case aiFeed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localUsage: return L10n.text("widget.local_usage")
        case .aiFeed: return L10n.text("widget.ai_feed")
        default: return provider?.displayName ?? rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "circle.hexagongrid"
        case .cursor: return "cursorarrow"
        case .grok: return "bolt"
        case .zai: return "z.square"
        case .copilot: return "airpodsmax"
        case .devin: return "hexagon"
        case .openrouter: return "arrow.triangle.branch"
        case .antigravity: return "arrow.up.forward"
        case .opencode: return "terminal"
        case .localUsage: return "chart.donut"
        case .aiFeed: return "newspaper"
        default: return "square.grid.2x2"
        }
    }

    var supportsExpansion: Bool {
        self != .localUsage
    }

    /// 挂件对应的额度 provider;本地用量与 AI Feed 挂件为 nil。
    var provider: ProviderQuota.Provider? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .cursor: return .cursor
        case .grok: return .grok
        case .zai: return .zai
        case .copilot: return .copilot
        case .devin: return .devin
        case .openrouter: return .openrouter
        case .antigravity: return .antigravity
        case .opencode: return .opencode
        case .deepseek: return .deepseek
        case .kimi: return .kimi
        case .minimax: return .minimax
        case .mimo: return .mimo
        case .qoder: return .qoder
        case .kiro: return .kiro
        case .volcengine: return .volcengine
        case .ollama: return .ollama
        case .localUsage, .aiFeed: return nil
        }
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
    static let defaultOrder: [PopoverWidget] = [
        .claude, .codex, .cursor, .copilot, .devin,
        .grok, .openrouter, .antigravity, .opencode, .zai,
        .deepseek, .kimi, .minimax, .mimo, .qoder, .kiro, .volcengine, .ollama,
        .localUsage, .aiFeed
    ]
    /// 首次出现时默认隐藏的挂件:主流三家之外的 provider 面向少数用户,
    /// 通过 "+" 菜单一键添加,不给其他用户增加弹窗长度。
    static let defaultHidden: Set<PopoverWidget> = [
        .grok, .zai, .copilot, .devin, .openrouter, .antigravity, .opencode,
        .deepseek, .kimi, .minimax, .mimo, .qoder, .kiro, .volcengine, .ollama
    ]

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
        // 该布局从未见过的挂件(known 兜底为持久化的 order)若在默认隐藏
        // 名单里,则以隐藏状态出现——老用户升级后弹窗不变长,新挂件从
        // "+" 菜单按需添加;一旦用户显示过,决定就持久化,不再强制隐藏。
        let known = Set((persisted?.known ?? persisted?.order ?? []).compactMap(PopoverWidget.init(rawValue:)))
        let newlyIntroduced = Self.defaultHidden.subtracting(known)
        hiddenWidgets = Set((persisted?.hidden ?? []).compactMap(PopoverWidget.init(rawValue:)))
            .union(persisted == nil ? Self.defaultHidden : newlyIntroduced)
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

    /// Drag-and-drop reordering uses the destination's current slot. Crossing
    /// an adjacent widget therefore moves that widget into the empty source
    /// slot immediately, matching the familiar Home Screen interaction.
    func move(_ widget: PopoverWidget, to destination: PopoverWidget) {
        guard widget != destination,
              order.contains(widget),
              let destinationIndex = order.firstIndex(of: destination)
        else { return }

        order.removeAll { $0 == widget }
        order.insert(widget, at: min(destinationIndex, order.count))
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
            pinned: Self.defaultOrder.filter(pinnedWidgets.contains).map(\.rawValue),
            known: PopoverWidget.allCases.map(\.rawValue)
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
        /// 该布局见过的全部挂件;老版本无此字段(nil),以 order 兜底判断
        /// 新挂件,保证默认隐藏只对"第一次出现"生效。
        let known: [String]?
    }
}
