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
        #expect(store.menuBarDisplayMode == .full)
        #expect(!store.showFableQuotaInMenuBarWidget)
        #expect(!store.showCodexSparkQuotaInMenuBarWidget)
        #expect(store.refreshMinutes == 5)
        #expect(store.refreshInterval == 300)
        #expect(!store.floatingWidgetEnabled)
    }

    @Test("Menu bar model quota preferences default off and persist")
    func menuBarModelQuotaPreferences() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)
        #expect(!store.showFableQuotaInMenuBarWidget)
        #expect(!store.showCodexSparkQuotaInMenuBarWidget)

        store.setShowFableQuotaInMenuBarWidget(true)
        store.setShowCodexSparkQuotaInMenuBarWidget(true)
        let reloaded = PreferencesStore(defaults: defaults)
        #expect(reloaded.showFableQuotaInMenuBarWidget)
        #expect(reloaded.showCodexSparkQuotaInMenuBarWidget)
    }

    @Test("Dashboard quota cards always include available model windows")
    func dashboardModelQuotaWindows() {
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: nil),
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 70, windowMinutes: 10_080, resetsAt: nil)
                ),
                ScopedQuotaWindow(
                    scopeID: "codex_bengalfox",
                    displayName: "GPT-5.3-Codex-Spark",
                    window: QuotaWindow(usedPercent: 30, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )

        #expect(QuotaCard.scopedWindows(in: quota).map(\.scopeID) == ["fable", "codex_bengalfox"])
    }

    @Test("Menu bar widget model rows honor both independent preferences")
    func menuBarWidgetModelQuotaFilters() {
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 70, windowMinutes: 10_080, resetsAt: nil)
                ),
                ScopedQuotaWindow(
                    scopeID: "codex_bengalfox",
                    displayName: "GPT-5.3-Codex-Spark",
                    window: QuotaWindow(usedPercent: 50, windowMinutes: 10_080, resetsAt: nil)
                ),
                ScopedQuotaWindow(
                    scopeID: "future_model",
                    displayName: "Future Model",
                    window: QuotaWindow(usedPercent: 30, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )

        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: false,
                showFable: false,
                showCodexSpark: false
            ).isEmpty
        )
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: false,
                showFable: true,
                showCodexSpark: false
            ).map(\.scopeID) == ["fable"]
        )
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: false,
                showFable: false,
                showCodexSpark: true
            ).map(\.scopeID) == ["codex_bengalfox"]
        )
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: true,
                showFable: false,
                showCodexSpark: false
            )
                .map(\.scopeID) == ["future_model"]
        )
    }

    @Test("Menu bar display mode persists and rejects unknown stored values")
    func menuBarDisplayMode() {
        let defaults = testDefaults()
        PreferencesStore(defaults: defaults).setMenuBarDisplayMode(.compact)
        #expect(PreferencesStore(defaults: defaults).menuBarDisplayMode == .compact)

        defaults.set("future-mode", forKey: PreferencesStore.menuBarDisplayModeKey)
        #expect(PreferencesStore(defaults: defaults).menuBarDisplayMode == .full)
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
