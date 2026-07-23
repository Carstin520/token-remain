import Foundation
import Testing
@testable import UsageDock

@Suite("Preferences store")
@MainActor
struct PreferencesStoreTests {
    @Test("Defaults keep the historical menu bar and cadence behavior")
    func defaults() {
        let store = PreferencesStore(defaults: testDefaults())
        #expect(store.menuBarProviders == [.claude, .codex])
        #expect(store.refreshMinutes == 5)
        #expect(store.refreshInterval == 300)
        #expect(!store.floatingWidgetEnabled)
    }

    @Test("Menu bar selection keeps display order and persists")
    func menuBarSelection() {
        let defaults = testDefaults()
        var store = PreferencesStore(defaults: defaults)
        store.toggleMenuBar(.zai)
        store.toggleMenuBar(.cursor)
        store.toggleMenuBar(.claude)

        // 无论点选顺序如何,渲染顺序始终跟 displayOrder。
        #expect(store.menuBarProviders == [.codex, .cursor, .zai])

        store = PreferencesStore(defaults: defaults)
        #expect(store.menuBarProviders == [.codex, .cursor, .zai])
    }

    @Test("Manual-only mode yields no auto interval; invalid choices are rejected")
    func refreshChoices() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)
        store.setRefreshMinutes(0)
        #expect(store.refreshInterval == nil)
        store.setRefreshMinutes(30)
        #expect(store.refreshInterval == 1800)
        store.setRefreshMinutes(7)
        #expect(store.refreshMinutes == 30)

        let reloaded = PreferencesStore(defaults: defaults)
        #expect(reloaded.refreshMinutes == 30)
    }

    @Test("Floating widget flag persists")
    func floatingFlag() {
        let defaults = testDefaults()
        PreferencesStore(defaults: defaults).setFloatingWidgetEnabled(true)
        #expect(PreferencesStore(defaults: defaults).floatingWidgetEnabled)
    }

    private func testDefaults() -> UserDefaults {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
