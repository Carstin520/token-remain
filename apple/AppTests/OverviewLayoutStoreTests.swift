import Foundation
import Testing
@testable import TokenRemain

@Suite("Overview widget layout")
@MainActor
struct OverviewLayoutStoreTests {
    @Test("Fresh installs show every default widget")
    func freshDefaultsAreVisible() throws {
        let suite = "OverviewLayoutFresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = OverviewLayoutStore(defaults: defaults)
        #expect(store.visibleWidgets == OverviewLayoutStore.Widget.allCases)
        #expect(store.availableWidgets.isEmpty)
    }

    @Test("Hide, restore, visible-only reorder, and expansion persist")
    func persistenceAndVisibleReorder() throws {
        let suite = "OverviewLayoutPersist-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var store = OverviewLayoutStore(defaults: defaults)
        store.hide(.codex)
        store.moveDown(.claude)
        store.toggleExpanded(.claude)

        #expect(store.visibleWidgets.first == .todayUsage)
        #expect(store.availableWidgets == [.codex])

        store = OverviewLayoutStore(defaults: defaults)
        #expect(store.visibleWidgets.first == .todayUsage)
        #expect(store.availableWidgets == [.codex])
        #expect(store.isExpanded(.claude))

        store.show(.codex)
        #expect(store.visibleWidgets.contains(.codex))
    }

    @Test("Feed post text collapses source whitespace for compact rows")
    func feedPostTextNormalization() {
        #expect(
            CuratedFeedWidget.normalizedPostText(
                "Introducing Claude Opus 5.\n\nIt's thoughtful\tand proactive."
            ) == "Introducing Claude Opus 5. It's thoughtful and proactive."
        )
    }
}
