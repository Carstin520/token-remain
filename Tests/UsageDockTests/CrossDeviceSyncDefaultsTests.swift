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

    @Test("Mac heartbeat stays within the five-minute delivery ceiling")
    func heartbeatCeiling() {
        #expect(CrossDeviceSyncController.heartbeatInterval == 5 * 60)
    }

    @Test("Publishing advances beyond the authenticated remote sequence")
    func remoteSequenceFloor() {
        #expect(SyncSequencePolicy.next(localSequence: 12, remoteSequence: 42) == 43)
        #expect(SyncSequencePolicy.next(localSequence: 50, remoteSequence: 42) == 51)
        #expect(SyncSequencePolicy.next(localSequence: 0, remoteSequence: nil) == 1)
        #expect(SyncSequencePolicy.next(localSequence: .max, remoteSequence: 42) == nil)
    }
}
#endif
