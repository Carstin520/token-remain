#if TOKENREMAIN_CLOUD_SYNC
import Foundation
import Testing
import TokenRemainSyncKit
@testable import UsageDock

private actor FakeMacSyncKeyStore: SyncKeyStoring {
    let records: [UUID: SyncKeyRecord]

    init(records: [UUID: SyncKeyRecord]) {
        self.records = records
    }

    func current() async throws -> SyncKeyRecord? { records.values.first }
    func load(keyID: UUID) async throws -> SyncKeyRecord? { records[keyID] }
    func loadOrCreate() async throws -> SyncKeyRecord { records.values.first! }
    func rotate() async throws -> SyncKeyRecord { records.values.first! }
    func delete(keyID: UUID) async throws {}
    func deleteAll() async throws {}
}

@Suite("Mobile snapshot redaction")
struct MobileSnapshotRedactorTests {
    @Test("All provider quotas cross only through the explicit allowlist")
    func allowlist() throws {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(
                usedPercent: 42,
                windowMinutes: 300,
                resetsAt: now + 60,
                remainingBalance: QuotaBalance(amount: 8.25, currencyCode: "USD")
            ),
            secondary: QuotaWindow(usedPercent: 7, windowMinutes: 10_080, resetsAt: nil),
            planName: "Max 5x",
            capturedAt: now,
            extraUsage: ExtraUsage(spentUSD: 12.34, monthlyLimitUSD: 50),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 63, windowMinutes: 10_080, resetsAt: now + 120)
                )
            ]
        )

        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: [.claude: quota],
            sourceInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            sequence: 1,
            generatedAt: now
        )
        let payload = try snapshot.encodedPayload()
        let text = try #require(String(data: payload, encoding: .utf8))

        #expect(snapshot.providers.map(\.providerID) == ["claude"])
        #expect(snapshot.providers.first?.planName == "Max 5x")
        #expect(snapshot.providers.first?.scopedWindows?.first?.scopeID == "fable")
        #expect(snapshot.providers.first?.scopedWindows?.first?.window.usedPercent == 63)
        #expect(snapshot.providers.first?.windows.first?.remainingBalance == SyncedQuotaBalance(
            amount: 8.25,
            currencyCode: "USD"
        ))
        #expect(snapshot.aggregateUsage == nil)
        #expect(snapshot.dailyUsageHistory == nil)
        #expect(text.contains("Max 5x"))
        #expect(!text.contains("spentUSD"))
        #expect(!text.contains("monthlyLimitUSD"))
        #expect(text.contains("planName"))
        #expect(text.contains("Fable"))
        #expect(!text.contains(ProviderQuota.Provider.claude.rawValue))
    }

    @Test("Every supported Mac provider is published and credential-like plan labels are removed")
    func allProviders() {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let values = ProviderQuota.Provider.displayOrder.map { provider in
            ProviderQuota(
                provider: provider,
                primary: QuotaWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now + 60),
                secondary: nil,
                planName: provider == .cursor ? "user@example.com" : "Pro",
                capturedAt: now
            )
        }
        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: Dictionary(uniqueKeysWithValues: values.map { ($0.provider, $0) }),
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )

        #expect(snapshot.providers.count == ProviderQuota.Provider.displayOrder.count)
        #expect(Set(snapshot.providers.map(\.providerID)) == SyncedProviderID.supportedOnCurrentMobile)
        #expect(snapshot.providers.first { $0.providerID == "cursor" }?.planName == nil)
    }

    @Test("Daily token and cost history requires separate opt-in and stays aggregate-only")
    func dailyHistoryOptIn() throws {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let history = DailyUsageHistory(
            days: [
                DailyUsageHistory.Day(
                    date: now - 86_400,
                    claudeTokens: 12_000_000,
                    claudeCost: 22.5,
                    codexTokens: 7_000_000,
                    codexCost: 9.75
                ),
                DailyUsageHistory.Day(
                    date: now,
                    claudeTokens: 14_000_000,
                    claudeCost: 25.5,
                    codexTokens: 8_000_000,
                    codexCost: 10.75
                )
            ],
            capturedAt: now
        )

        let off = MobileSnapshotRedactor.makeSnapshot(
            from: [:],
            history: history,
            includesUsageHistory: false,
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )
        #expect(off.dailyUsageHistory == nil)

        let on = MobileSnapshotRedactor.makeSnapshot(
            from: [:],
            history: history,
            includesUsageHistory: true,
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )
        let synced = try #require(on.dailyUsageHistory)
        #expect(synced.days.count == 2)
        #expect(synced.days.last?.claudeTokens == 14_000_000)
        #expect(synced.days.last?.codexCost == 10.75)

        let payload = try on.encodedPayload()
        let text = try #require(String(data: payload, encoding: .utf8))
        for deniedField in ["prompt", "project", "session", "account", "path", "request"] {
            #expect(!text.lowercased().contains(deniedField))
        }
        #expect(throws: Never.self) {
            try on.validatedForTransport(configuration: .current(now: now))
        }
    }

    @Test("Daily history day keys are canonical UTC across the local midnight boundary")
    func dailyHistoryUsesUTCDayKeys() throws {
        let utcMidnight = Date(timeIntervalSince1970: 1_784_764_800)
        let now = utcMidnight.addingTimeInterval(30 * 60)
        let history = DailyUsageHistory(
            days: [
                DailyUsageHistory.Day(
                    date: utcMidnight.addingTimeInterval(-30 * 60),
                    claudeTokens: 1,
                    claudeCost: 0,
                    codexTokens: 0,
                    codexCost: 0
                ),
                DailyUsageHistory.Day(
                    date: now,
                    claudeTokens: 2,
                    claudeCost: 0,
                    codexTokens: 0,
                    codexCost: 0
                )
            ],
            capturedAt: now
        )

        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: [:],
            history: history,
            includesUsageHistory: true,
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )

        #expect(try #require(snapshot.dailyUsageHistory).days.map(\.day) == [
            "2026-07-22",
            "2026-07-23"
        ])
    }

    @Test("Every macOS provider has a well-formed stable wire identifier")
    func stableProviderIdentifiers() {
        let identifiers = ProviderQuota.Provider.displayOrder.map(MobileSnapshotRedactor.stableID)
        #expect(Set(identifiers).count == ProviderQuota.Provider.displayOrder.count)
        #expect(identifiers.allSatisfy(SyncedProviderID.isWellFormed))
        #expect(Set(identifiers) == SyncedProviderID.supportedOnCurrentMobile)
    }

    @Test("Outgoing percentages are bounded and lifetime is capped")
    func bounds() throws {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let quota = ProviderQuota(
            provider: .codex,
            primary: QuotaWindow(usedPercent: 140, windowMinutes: -1, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: now
        )
        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: [.codex: quota],
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )

        #expect(snapshot.providers[0].windows[0].usedPercent == 100)
        #expect(snapshot.providers[0].windows[0].windowMinutes == 0)
        #expect(snapshot.expiresAt.timeIntervalSince(snapshot.generatedAt) == 24 * 60 * 60)
        #expect(throws: Never.self) {
            try snapshot.validatedForTransport(configuration: .current(now: now))
        }
    }

    @Test("A remote source header is trusted only after envelope authentication")
    func authenticatesRemoteSource() async throws {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let key = try SyncKeyRecord(keyID: UUID(), key: .random())
        let sourceID = UUID()
        let snapshot = MobileUsageSnapshot(
            sourceInstanceID: sourceID,
            sequence: 1,
            generatedAt: now,
            expiresAt: now + 600,
            providers: []
        )
        let envelope = try EncryptedSyncEnvelope.seal(
            snapshot,
            using: key.key,
            keyID: key.keyID,
            containerID: CrossDeviceSyncController.cloudContainerIdentifier,
            configuration: .current(now: now)
        )
        let validRecord = try CloudKitSyncRecordCodec.record(for: envelope)
        let validStored = try CloudKitSyncRecordCodec.storedEnvelope(from: validRecord)
        let keys = FakeMacSyncKeyStore(records: [key.keyID: key])

        #expect(try await MacSyncRemoteSourceAuthenticator.sourceInstanceID(
            from: validStored,
            keyStore: keys,
            containerIdentifier: CrossDeviceSyncController.cloudContainerIdentifier,
            now: now
        ) == sourceID)

        var tamperedPayload = envelope.sealedPayload
        tamperedPayload[tamperedPayload.startIndex] ^= 0x01
        let tamperedEnvelope = try EncryptedSyncEnvelope(
            keyID: envelope.keyID,
            sourceInstanceID: envelope.sourceInstanceID,
            sequence: envelope.sequence,
            generatedAt: envelope.generatedAt,
            sealedPayload: tamperedPayload
        )
        let tamperedRecord = try CloudKitSyncRecordCodec.record(for: tamperedEnvelope)
        let tamperedStored = try CloudKitSyncRecordCodec.storedEnvelope(from: tamperedRecord)

        await #expect(throws: SyncProtocolError.authenticationFailed) {
            try await MacSyncRemoteSourceAuthenticator.sourceInstanceID(
                from: tamperedStored,
                keyStore: keys,
                containerIdentifier: CrossDeviceSyncController.cloudContainerIdentifier,
                now: now
            )
        }
    }
}
#endif
