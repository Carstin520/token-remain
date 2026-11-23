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

    /// 没有 5 小时窗的 Claude 套餐只有一个账户级窗口,外加新出现的分项 ID 和
    /// 显示名。线上结构不变:它们必须过白名单与窗口上限,并原样往返。
    @Test("A weekly-only Claude quota with the new scoped rows round-trips unchanged")
    func weeklyOnlyClaudeRoundTrips() throws {
        let now = Date()
        let reset = now.addingTimeInterval(86_400)
        func scoped(_ id: String, _ name: String, _ minutes: Int, _ used: Double) -> ScopedQuotaWindow {
            ScopedQuotaWindow(
                scopeID: id,
                displayName: name,
                window: QuotaWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset),
                observedAt: now
            )
        }
        let rows = [
            scoped("fable_session", "Fable", 300, 88),
            scoped("fable", "Fable", 10_080, 64),
            scoped("claude_code", "Claude Code", 10_080, 9),
            scoped("fable_claude_code", "Fable · Claude Code", 10_080, 40),
            scoped("opus_30d", "Opus", 43_200, 5),
            scoped("overall_30d", "Overall", 43_200, 72),
        ]
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 31, windowMinutes: 10_080, resetsAt: reset),
            secondary: nil,
            planName: "Ultra",
            capturedAt: now,
            scopedWindows: rows
        )
        #expect(rows.allSatisfy(MobileSnapshotRedactor.isWireSafe))

        let snapshot = try MobileSnapshotRedactor.makeSnapshot(
            from: [.claude: quota],
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        ).validatedForTransport()
        let wire = try #require(snapshot.providers.first)
        #expect(wire.windows.map(\.windowMinutes) == [10_080])
        #expect(wire.windows.count + (wire.scopedWindows?.count ?? 0)
            <= MobileSnapshotRedactor.maximumSyncedWindowsPerProvider)

        let restored = try #require(DirectSyncSnapshotAdapter.quotas(from: snapshot)[.claude])
        #expect(restored.primary.windowMinutes == 10_080)
        #expect(restored.primary.usedPercent == 31)
        #expect(restored.secondary == nil)
        #expect(restored.planName == "Ultra")
        #expect(restored.uniqueScopedWindows.map(\.scopeID) == rows.map(\.scopeID))
        #expect(restored.uniqueScopedWindows.map(\.displayName) == rows.map(\.displayName))
        #expect(restored.fableWindow?.scopeID == "fable")
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
