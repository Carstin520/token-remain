#if TOKENREMAIN_CLOUD_SYNC
import Foundation
import Testing
@testable import UsageDock

@Suite("Cross-device sync defaults")
struct CrossDeviceSyncDefaultsTests {
    @Test("A fresh Mac installation enables private sync automatically")
    @MainActor
    func freshInstallDefaultsToEnabled() {
        let suite = "TokenRemainMacSyncDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = CrossDeviceSyncController(defaults: defaults)
        #expect(controller.isEnabled)

        controller.setEnabled(false)
        let restored = CrossDeviceSyncController(defaults: defaults)
        #expect(restored.isEnabled == false)
    }
}
#endif
