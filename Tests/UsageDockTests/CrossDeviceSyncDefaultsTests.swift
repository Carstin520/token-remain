#if TOKENREMAIN_CLOUD_SYNC
import Foundation
import Testing
@testable import UsageDock

@Suite("Cross-device sync defaults")
struct CrossDeviceSyncDefaultsTests {
    @Test("A fresh Mac installation keeps private sync off until the user opts in")
    @MainActor
    func freshInstallDefaultsToDisabled() {
        let suite = "TokenRemainMacSyncDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = CrossDeviceSyncController(defaults: defaults)
        #expect(controller.isEnabled == false)

        controller.setEnabled(true)
        let restored = CrossDeviceSyncController(defaults: defaults)
        #expect(restored.isEnabled)
    }

    @Test("An upgrade keeps sync on for installs that have already uploaded")
    @MainActor
    func upgradeGrandfathersActiveSync() {
        let suite = "TokenRemainMacSyncDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // 旧版默认开启的安装若已成功上传过,视为 iPhone 端在用。
        defaults.set(Date(), forKey: "crossDeviceSync.lastUploadedAt")
        let upgraded = CrossDeviceSyncController(defaults: defaults)
        #expect(upgraded.isEnabled)

        // 用户显式关过的安装不因上传历史被重新打开。
        upgraded.setEnabled(false)
        let restored = CrossDeviceSyncController(defaults: defaults)
        #expect(restored.isEnabled == false)
    }

    @Test("Mac heartbeat stays far inside the 24-hour snapshot lifetime")
    func heartbeatCeiling() {
        #expect(CrossDeviceSyncController.heartbeatInterval == 15 * 60)
    }

    @Test("Publishing advances beyond the authenticated remote sequence")
    func remoteSequenceFloor() {
        #expect(SyncSequencePolicy.next(localSequence: 12, remoteSequence: 42) == 43)
        #expect(SyncSequencePolicy.next(localSequence: 50, remoteSequence: 42) == 51)
        #expect(SyncSequencePolicy.next(localSequence: 0, remoteSequence: nil) == 1)
        #expect(SyncSequencePolicy.next(localSequence: .max, remoteSequence: 42) == nil)
    }

    @Test("Legacy current record never blocks independent source publishing")
    func legacyCompatibilityWritePolicy() {
        let local = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
        let foreign = UUID(uuidString: "00000000-0000-4000-8000-000000000022")!

        #expect(LegacyCompatibilityWritePolicy.shouldWrite(
            localSourceID: local,
            currentRecordExists: false,
            authenticatedOwner: nil,
            currentRecordIsExpired: false
        ))
        #expect(LegacyCompatibilityWritePolicy.shouldWrite(
            localSourceID: local,
            currentRecordExists: true,
            authenticatedOwner: local,
            currentRecordIsExpired: false
        ))
        #expect(!LegacyCompatibilityWritePolicy.shouldWrite(
            localSourceID: local,
            currentRecordExists: true,
            authenticatedOwner: foreign,
            currentRecordIsExpired: false
        ))
        #expect(!LegacyCompatibilityWritePolicy.shouldWrite(
            localSourceID: local,
            currentRecordExists: true,
            authenticatedOwner: nil,
            currentRecordIsExpired: false
        ))
        #expect(LegacyCompatibilityWritePolicy.shouldWrite(
            localSourceID: local,
            currentRecordExists: true,
            authenticatedOwner: nil,
            currentRecordIsExpired: true
        ))
    }
}
#endif
