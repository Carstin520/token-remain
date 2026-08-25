import Foundation
import Testing
@testable import UsageDock

@MainActor
@Suite("Direct sync settings")
struct DirectSyncControllerTests {
    @Test("Daily usage sharing is separate, explicit, and persisted")
    func dailyUsageSharingPreference() throws {
        let suiteName = "DirectSyncControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = DirectSyncController(defaults: defaults)
        #expect(first.sharesUsageHistory == false)
        first.setSharesUsageHistory(true)
        #expect(first.sharesUsageHistory == true)

        let restored = DirectSyncController(defaults: defaults)
        #expect(restored.sharesUsageHistory == true)
    }
}
