import Foundation
import Testing
import TokenRemainSyncKit
@testable import UsageDock

@Suite("Direct sync snapshot adapter")
struct DirectSyncSnapshotAdapterTests {
    @Test("Remote provider windows are normalized into the existing quota model")
    func adaptsProvider() {
        let now = Date()
        let snapshot = MobileUsageSnapshot(
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now,
            expiresAt: now + 600,
            providers: [
                SyncedProviderQuota(
                    providerID: SyncedProviderID.codex,
                    windows: [
                        SyncedQuotaWindow(usedPercent: 25, windowMinutes: 10_080, resetsAt: now + 500),
                        SyncedQuotaWindow(usedPercent: 75, windowMinutes: 300, resetsAt: now + 100),
                    ],
                    capturedAt: now,
                    statusCode: .available,
                    planName: "Pro 5x"
                )
            ]
        )

        let quota = DirectSyncSnapshotAdapter.quotas(from: snapshot)[.codex]
        #expect(quota?.primary.windowMinutes == 300)
        #expect(quota?.primary.usedPercent == 75)
        #expect(quota?.secondary?.windowMinutes == 10_080)
        #expect(quota?.planName == "Pro 5x")
    }

    @Test("Mac redactor remains an explicit credential-free allowlist")
    func redactor() {
        let now = Date()
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: now + 300),
            secondary: nil,
            planName: "Max 20x",
            capturedAt: now,
            extraUsage: ExtraUsage(spentUSD: 12, monthlyLimitUSD: 50)
        )
        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: [.claude: quota],
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )

        #expect(snapshot.providers.count == 1)
        #expect(snapshot.providers[0].providerID == "claude")
        #expect(snapshot.aggregateUsage == nil)
        #expect(snapshot.dailyUsageHistory == nil)
    }
}
