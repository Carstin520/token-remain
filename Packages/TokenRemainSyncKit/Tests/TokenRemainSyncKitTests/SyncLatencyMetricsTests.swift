import Foundation
import Testing
@testable import TokenRemainSyncKit

@Suite("Cross-device latency metrics")
struct SyncLatencyMetricsTests {
    private let start = Date(timeIntervalSince1970: 1_784_764_800)

    @Test("Nearest-rank p50 and p95 use only chronological observations")
    func percentiles() throws {
        let valid = try (1...20).map { seconds in
            try #require(SyncLatencyObservation(
                providerID: SyncedProviderID.claude,
                providerCapturedAt: start,
                macUploadedAt: start + 0.25,
                phoneReceivedAt: start + Double(seconds) - 0.25,
                phoneRenderedAt: start + Double(seconds)
            ))
        }
        let invalidOrder = try #require(SyncLatencyObservation(
            providerID: SyncedProviderID.codex,
            providerCapturedAt: start + 10,
            macUploadedAt: start + 5,
            phoneReceivedAt: start + 6,
            phoneRenderedAt: start + 7
        ))

        let summary = try #require(SyncLatencySummary.calculate(from: valid + [invalidOrder]))
        #expect(summary.sampleCount == 20)
        #expect(summary.p50Seconds == 10)
        #expect(summary.p95Seconds == 19)
        #expect(summary.maximumSeconds == 20)
    }

    @Test("Observation rejects account-like provider identifiers and invalid dates")
    func privacyBoundary() {
        #expect(SyncLatencyObservation(
            providerID: "person@example.com",
            providerCapturedAt: start,
            macUploadedAt: start,
            phoneReceivedAt: start,
            phoneRenderedAt: start
        ) == nil)
        #expect(SyncLatencyObservation(
            providerID: SyncedProviderID.codex,
            providerCapturedAt: Date(timeIntervalSince1970: .infinity),
            macUploadedAt: start,
            phoneReceivedAt: start,
            phoneRenderedAt: start
        ) == nil)
    }
}
