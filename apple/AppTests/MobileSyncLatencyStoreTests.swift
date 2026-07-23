import Foundation
import Testing
import TokenRemainSyncKit
@testable import TokenRemain

@Suite("iPhone sync latency persistence")
struct MobileSyncLatencyStoreTests {
    @Test("Records four timing boundaries without quota values or account data")
    func recordsAndSummarizes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenRemainLatencyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileSyncLatencyStore(directory: directory)
        let capturedAt = Date(timeIntervalSince1970: 1_784_764_800)
        let uploadedAt = capturedAt + 4
        let receivedAt = capturedAt + 44
        let renderedAt = capturedAt + 45
        let snapshot = MobileUsageSnapshot(
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: uploadedAt,
            expiresAt: uploadedAt + 600,
            providers: [SyncedProviderQuota(
                providerID: SyncedProviderID.claude,
                windows: [SyncedQuotaWindow(
                    usedPercent: 42,
                    windowMinutes: 300,
                    resetsAt: capturedAt + 300
                )],
                capturedAt: capturedAt,
                statusCode: .available
            )]
        )
        let delivery = MobileSyncDelivery(
            snapshot: snapshot,
            macUploadedAt: uploadedAt,
            phoneReceivedAt: receivedAt
        )

        let summary = try #require(store.record(delivery, phoneRenderedAt: renderedAt))
        let observation = try #require(store.observations().first)
        #expect(summary.sampleCount == 1)
        #expect(summary.p50Seconds == 45)
        #expect(summary.p95Seconds == 45)
        #expect(observation.providerID == SyncedProviderID.claude)
        #expect(observation.providerCapturedAt == capturedAt)
        #expect(observation.macUploadedAt == uploadedAt)
        #expect(observation.phoneReceivedAt == receivedAt)
        #expect(observation.phoneRenderedAt == renderedAt)

        let data = try Data(contentsOf: directory.appendingPathComponent("sync-latency-v1.json"))
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let keys = try #require(array.first.map { Set($0.keys) })
        #expect(keys == [
            "providerID", "providerCapturedAt", "macUploadedAt",
            "phoneReceivedAt", "phoneRenderedAt",
        ])
    }
}
