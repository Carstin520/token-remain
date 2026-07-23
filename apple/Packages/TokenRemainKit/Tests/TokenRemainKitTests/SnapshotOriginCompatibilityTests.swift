import Foundation
import Testing
@testable import TokenRemainKit

@Suite("Snapshot origin compatibility")
struct SnapshotOriginCompatibilityTests {
    @Test("mac-sync origin composes only an honest placeholder")
    func macSyncComposerHonesty() {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let composed = SnapshotComposer.compose(origin: .macSync, scenario: .concept, now: now)

        #expect(composed.origin == .macSync)
        #expect(composed.providers.isEmpty)
        #expect(composed.dailyTokens == nil)
        #expect(composed.isEmpty)
    }

    @Test("Existing origins retain their persisted raw values")
    func originRawValueCompatibility() {
        #expect(SnapshotOrigin(rawValue: "demo") == .demo)
        #expect(SnapshotOrigin(rawValue: "none") == SnapshotOrigin.none)
        #expect(SnapshotOrigin(rawValue: "macSync") == .macSync)
        #expect(SnapshotOrigin(rawValue: "future-origin") == nil)
    }

    @Test("mac-sync numbers fail closed after the 24-hour hard expiry")
    func macSyncHardExpiry() {
        let generatedAt = Date(timeIntervalSince1970: 1_784_764_800)
        let demo = SnapshotComposer.demo(scenario: .concept, now: generatedAt)
        let snapshot = UsageSnapshot(
            origin: .macSync,
            generatedAt: generatedAt,
            providers: demo.providers,
            dailyTokens: nil
        )

        let fresh = TREntry(snapshot: snapshot, now: generatedAt + 60)
        #expect(fresh.hasNumbers)
        #expect(!fresh.isStale)
        #expect(!fresh.isExpired)

        let stale = TREntry(
            snapshot: snapshot,
            now: generatedAt + UsageSnapshot.macSyncStaleInterval + 1
        )
        #expect(stale.hasNumbers)
        #expect(stale.isStale)
        #expect(!stale.isExpired)

        let expired = TREntry(
            snapshot: snapshot,
            now: generatedAt + UsageSnapshot.macSyncHardExpiry + 1
        )
        #expect(!expired.hasNumbers)
        #expect(expired.isStale)
        #expect(expired.isExpired)
        #expect(expired.providers.isEmpty)
        #expect(expired.paceLine == TRL10n.t("origin.macsync.expired"))

        let oldDemo = TREntry(
            snapshot: demo,
            now: generatedAt + UsageSnapshot.macSyncHardExpiry + 1
        )
        #expect(oldDemo.hasNumbers)
        #expect(!oldDemo.isStale)
        #expect(!oldDemo.isExpired)
    }
}
