import Foundation
import Testing
@testable import UsageDock

@Suite("Tracked providers store")
@MainActor
struct TrackedProvidersStoreTests {
    @Test("Background installation detection uses a five-minute cadence")
    func installationDetectionCadence() {
        #expect(TrackedProvidersStore.detectionMonitoringIntervalSeconds == 300)
    }

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

    @Test("Only a successful connection is remembered and failures never erase it")
    func connectionHistoryPersistsIndependently() {
        let defaults = testDefaults()
        var store = TrackedProvidersStore(defaults: defaults)

        #expect(store.connectedOrdered.isEmpty)
        store.setEnabled(.cursor, true)
        #expect(!store.hasConnected(.cursor))

        store.markConnected(.cursor)
        store.setEnabled(.cursor, false)

        store = TrackedProvidersStore(defaults: defaults)
        #expect(store.hasConnected(.cursor))
        #expect(store.connectedOrdered == [.cursor])
        #expect(!store.isEnabled(.cursor))
    }

    @Test("Manual credential sources are visible before their first connection")
    func manualCredentialSourcesAreVisibleForSetup() {
        let store = TrackedProvidersStore(defaults: testDefaults())
        store.completeOnboarding(enabled: [.cursor, .zai, .openrouter, .deepseek])

        #expect(store.connectedOrdered.isEmpty)
        #expect(store.dataSourceOrdered == [.openrouter, .zai, .deepseek])

        store.markConnected(.cursor)
        #expect(store.dataSourceOrdered == [.cursor, .openrouter, .zai, .deepseek])
    }

    @Test("Tracked Claude and Codex expose their first-use authorization rows")
    func desktopCredentialSourcesAreVisibleForSetup() {
        let store = TrackedProvidersStore(defaults: testDefaults())
        store.completeOnboarding(enabled: [.claude, .codex])
        #expect(store.connectedOrdered.isEmpty)
        #expect(store.dataSourceOrdered == [.claude, .codex])
    }

    @Test("Every manual credential provider has a first-use data source entry")
    func everyManualCredentialProviderIsVisibleForSetup() {
        let expected = Set(
            [.zai, .openrouter]
                + ProviderSecretStore.descriptors.map(\.provider)
        )
        let classified = Set(
            TrackedProvidersStore.allProviders.filter(
                TrackedProvidersStore.requiresManualCredential
            )
        )
        #expect(classified == expected)

        let store = TrackedProvidersStore(defaults: testDefaults())
        store.completeOnboarding(enabled: expected)
        #expect(Set(store.dataSourceOrdered) == expected)
    }

    @Test("A disabled unconnected credential source is not shown")
    func disabledCredentialSourceIsHiddenUntilConnected() {
        let store = TrackedProvidersStore(defaults: testDefaults())
        store.completeOnboarding(enabled: [.zai])
        #expect(store.dataSourceOrdered == [.zai])

        store.setEnabled(.zai, false)
        #expect(store.dataSourceOrdered.isEmpty)

        store.markConnected(.zai)
        #expect(store.dataSourceOrdered == [.zai])
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
        let localBin = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let claudeExecutable = localBin.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: claudeExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: claudeExecutable.path
        )

        let detections = TrackedProvidersStore.detections(
            home: home,
            environment: [:],
            applicationDirectories: []
        )
        let byProvider = Dictionary(uniqueKeysWithValues: detections.map { ($0.provider, $0.installed) })

        #expect(detections.map(\.provider) == TrackedProvidersStore.allProviders)
        #expect(byProvider[.claude] == true)
        #expect(byProvider[.codex] == true)
        #expect(byProvider[.grok] == true)
        #expect(byProvider[.zai] == false)
    }

    @Test("Claude and current or legacy Codex desktop apps are detected without CLI markers")
    func desktopAppsAreDetected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-desktop-detection-\(UUID().uuidString)", isDirectory: true)
        let home = root.appending(path: "home")
        let applications = root.appending(path: "Applications")
        try FileManager.default.createDirectory(
            at: applications.appending(path: "Claude.app"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: applications.appending(path: "ChatGPT.app"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let detections = TrackedProvidersStore.detections(
            home: home,
            environment: [:],
            applicationDirectories: [applications]
        )
        let byProvider = Dictionary(uniqueKeysWithValues: detections.map { ($0.provider, $0.installed) })
        #expect(byProvider[.claude] == true)
        #expect(byProvider[.codex] == true)

        try FileManager.default.removeItem(at: applications.appending(path: "ChatGPT.app"))
        try FileManager.default.createDirectory(
            at: applications.appending(path: "Codex.app"),
            withIntermediateDirectories: true
        )
        let legacyDetections = TrackedProvidersStore.detections(
            home: home,
            environment: [:],
            applicationDirectories: [applications]
        )
        #expect(legacyDetections.first { $0.provider == .codex }?.installed == true)
    }

    @Test("An empty isolated machine does not invent Claude or Codex installations")
    func emptyMachineDetectionIsHermetic() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-empty-machine-\(UUID().uuidString)", isDirectory: true)
        let detections = TrackedProvidersStore.detections(
            home: home,
            environment: [:],
            applicationDirectories: []
        )
        #expect(detections.first { $0.provider == .claude }?.installed == false)
        #expect(detections.first { $0.provider == .codex }?.installed == false)
    }

    @Test("Automatic scans exclude every manual credential provider")
    func automaticScansExcludeManualCredentials() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-auto-detection-\(UUID().uuidString)", isDirectory: true)
        let detections = TrackedProvidersStore.automaticDetections(
            home: home,
            environment: [
                "ZAI_API_KEY": "zai-test",
                "OPENROUTER_API_KEY": "openrouter-test",
                "DEEPSEEK_API_KEY": "deepseek-test"
            ]
        )
        #expect(
            detections.allSatisfy {
                !TrackedProvidersStore.requiresManualCredential($0.provider)
            }
        )
    }

    @Test("A tool installed later is suggested once and accepted into tracking")
    func laterInstallationIsSuggestedOnce() {
        let defaults = testDefaults()
        let store = TrackedProvidersStore(defaults: defaults)
        store.completeOnboarding(enabled: [])

        #expect(store.applyAutomaticDetections([]).isEmpty)
        let claude = TrackedProvidersStore.Detection(
            provider: .claude,
            installed: true,
            detail: "Found Claude Code"
        )
        #expect(store.applyAutomaticDetections([claude]) == [claude])
        #expect(store.pendingDetectionSuggestions == [claude])

        store.acceptNextDetectionSuggestion()
        #expect(store.isEnabled(.claude))
        #expect(store.pendingDetectionSuggestions.isEmpty)
        #expect(store.applyAutomaticDetections([claude]).isEmpty)
    }

    @Test("Installations found while TokenRemain was closed are compared with the saved baseline")
    func offlineInstallationIsSuggestedOnNextLaunch() {
        let defaults = testDefaults()
        var store = TrackedProvidersStore(defaults: defaults)
        store.completeOnboarding(enabled: [])
        store.applyAutomaticDetections([])

        store = TrackedProvidersStore(defaults: defaults)
        let codex = TrackedProvidersStore.Detection(
            provider: .codex,
            installed: true,
            detail: "Found Codex"
        )
        #expect(store.applyAutomaticDetections([codex]) == [codex])
        store.dismissNextDetectionSuggestion()
        #expect(store.applyAutomaticDetections([codex]).isEmpty)
        #expect(!store.isEnabled(.codex))
    }

    @Test("A configured ZAI_API_KEY marks Z.ai as detected")
    func zaiDetectedViaEnvironment() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-empty-\(UUID().uuidString)", isDirectory: true)
        let detections = TrackedProvidersStore.detections(
            home: home,
            environment: ["ZAI_API_KEY": "test-key"],
            applicationDirectories: []
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
