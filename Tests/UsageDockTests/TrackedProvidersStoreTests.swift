import Foundation
import Testing
@testable import UsageDock

@Suite("Tracked providers store")
@MainActor
struct TrackedProvidersStoreTests {
    @Test("Without a saved choice every provider is tracked (legacy behavior)")
    func defaultsToAllProviders() {
        let store = TrackedProvidersStore(defaults: testDefaults())
        #expect(store.enabled == Set(TrackedProvidersStore.allProviders))
        #expect(!store.hasCompletedOnboarding)
        #expect(store.enabledOrdered == TrackedProvidersStore.allProviders)
        #expect(store.disabledOrdered.isEmpty)
    }

    @Test("Onboarding confirmation persists the selection and the flag")
    func onboardingPersists() {
        let defaults = testDefaults()
        var store = TrackedProvidersStore(defaults: defaults)
        store.completeOnboarding(enabled: [.claude, .cursor])

        store = TrackedProvidersStore(defaults: defaults)
        #expect(store.hasCompletedOnboarding)
        #expect(store.enabled == [.claude, .cursor])
        #expect(store.enabledOrdered == [.claude, .cursor])
        #expect(store.disabledOrdered == TrackedProvidersStore.allProviders.filter { ![.claude, .cursor].contains($0) })
    }

    @Test("Later add and remove survive a new store instance")
    func addRemovePersist() {
        let defaults = testDefaults()
        var store = TrackedProvidersStore(defaults: defaults)
        store.completeOnboarding(enabled: [.claude])

        store.setEnabled(.zai, true)
        store.setEnabled(.claude, false)

        store = TrackedProvidersStore(defaults: defaults)
        #expect(store.enabled == [.zai])
    }

    @Test("Dashboard card order survives a new store instance")
    func providerOrderPersists() {
        let defaults = testDefaults()
        var store = TrackedProvidersStore(defaults: defaults)

        store.move(.cursor, before: .claude)
        #expect(Array(store.enabledOrdered.prefix(3)) == [.cursor, .claude, .codex])

        store = TrackedProvidersStore(defaults: defaults)
        #expect(Array(store.enabledOrdered.prefix(3)) == [.cursor, .claude, .codex])
    }

    @Test("Dragging across an adjacent card swaps into its current grid slot")
    func dragMovesIntoDestinationSlot() {
        let store = TrackedProvidersStore(defaults: testDefaults())

        store.move(.claude, to: .codex)

        #expect(Array(store.enabledOrdered.prefix(3)) == [.codex, .claude, .cursor])
    }

    @Test("Detection flags installed tools from real filesystem markers")
    func detectionFromMarkers() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-onboarding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appending(path: ".codex"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appending(path: ".grok"), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: home.appending(path: ".grok/auth.json"))

        let detections = TrackedProvidersStore.detections(home: home, environment: [:])
        let byProvider = Dictionary(uniqueKeysWithValues: detections.map { ($0.provider, $0.installed) })

        #expect(detections.map(\.provider) == TrackedProvidersStore.allProviders)
        #expect(byProvider[.claude] == false)
        #expect(byProvider[.codex] == true)
        #expect(byProvider[.grok] == true)
        #expect(byProvider[.zai] == false)
    }

    @Test("A configured ZAI_API_KEY marks Z.ai as detected")
    func zaiDetectedViaEnvironment() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-empty-\(UUID().uuidString)", isDirectory: true)
        let detections = TrackedProvidersStore.detections(
            home: home,
            environment: ["ZAI_API_KEY": "test-key"]
        )
        #expect(detections.first { $0.provider == .zai }?.installed == true)
    }

    private func testDefaults() -> UserDefaults {
        let suiteName = "TrackedProvidersStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
