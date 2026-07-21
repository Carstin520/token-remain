import Foundation
import Testing
@testable import UsageDock

@Suite("Popover widget layout")
struct PopoverLayoutStoreTests {
    @Test("Default order keeps providers first and AI Feed last")
    func defaultOrder() {
        let defaults = testDefaults()
        let store = PopoverLayoutStore(defaults: defaults)

        // 主流三家之外的 provider 挂件首次出现默认隐藏,由 "+" 菜单按需添加。
        #expect(store.visibleWidgets == [.claude, .codex, .cursor, .localUsage, .aiFeed])
        #expect(store.availableWidgets == PopoverLayoutStore.defaultOrder.filter(PopoverLayoutStore.defaultHidden.contains))
        #expect(PopoverWidget.aiFeed.title == "AI动态")
    }

    @Test("Collapsed provider card always chooses the shortest quota window")
    func shortestWindowWinsOverLowestRemaining() throws {
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 95, windowMinutes: 10_080, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            planName: nil,
            capturedAt: .now
        )

        let window = try #require(PopoverQuotaWidget.shortestWindow(in: quota))
        #expect(window.windowMinutes == 300)
        #expect(window.usedPercent == 10)
    }

    @Test("Hidden widgets can be restored without losing their order")
    func hideAndRestore() {
        let defaults = testDefaults()
        let store = PopoverLayoutStore(defaults: defaults)

        store.hide(.localUsage)
        #expect(store.visibleWidgets == [.claude, .codex, .cursor, .aiFeed])
        #expect(Set(store.availableWidgets) == PopoverLayoutStore.defaultHidden.union([.localUsage]))

        store.show(.localUsage)
        #expect(store.visibleWidgets == [.claude, .codex, .cursor, .localUsage, .aiFeed])
    }

    @Test("Order and pinned expansion survive a new store")
    func persistence() {
        let defaults = testDefaults()
        var store = PopoverLayoutStore(defaults: defaults)
        store.move(.aiFeed, before: .claude)
        store.togglePinned(.codex)

        store = PopoverLayoutStore(defaults: defaults)
        #expect(store.visibleWidgets == [.aiFeed, .claude, .codex, .cursor, .localUsage])
        #expect(store.isPinned(.codex))
        #expect(store.isExpanded(.codex))
    }

    @Test("Dragging across an adjacent widget swaps into its current slot")
    func dragMovesIntoDestinationSlot() {
        let store = PopoverLayoutStore(defaults: testDefaults())

        store.move(.claude, to: .codex)

        #expect(Array(store.order.prefix(3)) == [.codex, .claude, .cursor])
    }

    @Test("A newly shown default-hidden widget stays visible across stores")
    func defaultHiddenWidgetStaysVisibleOnceShown() {
        let defaults = testDefaults()
        var store = PopoverLayoutStore(defaults: defaults)
        store.show(.grok)
        #expect(store.visibleWidgets.contains(.grok))

        // 用户显示过一次后,该决定持久化——新 store 不再强制隐藏。
        store = PopoverLayoutStore(defaults: defaults)
        #expect(store.visibleWidgets.contains(.grok))
        #expect(Set(store.availableWidgets) == PopoverLayoutStore.defaultHidden.subtracting([.grok]))
    }

    @Test("Collapsing a pinned widget unpins it in one action")
    func collapsingPinnedUnpins() {
        let defaults = testDefaults()
        var store = PopoverLayoutStore(defaults: defaults)

        store.togglePinned(.codex)
        #expect(store.isPinned(.codex))
        #expect(store.isExpanded(.codex))

        // Collapsing the pinned widget releases the pin AND collapses — no
        // blocking prompt, no separate unpin step.
        store.toggleExpanded(.codex)
        #expect(!store.isPinned(.codex))
        #expect(!store.isExpanded(.codex))

        // The unpin is durable across a fresh store.
        store = PopoverLayoutStore(defaults: defaults)
        #expect(!store.isPinned(.codex))
        #expect(!store.isExpanded(.codex))
    }

    @Test("Only pinned widgets reopen expanded")
    func expansionSemantics() {
        let defaults = testDefaults()
        let store = PopoverLayoutStore(defaults: defaults)

        store.toggleExpanded(.claude)
        store.togglePinned(.codex)
        #expect(store.isExpanded(.claude))
        #expect(store.isExpanded(.codex))

        store.prepareForPresentation()
        #expect(!store.isExpanded(.claude))
        #expect(store.isExpanded(.codex))
    }

    private func testDefaults() -> UserDefaults {
        let suiteName = "PopoverLayoutStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
