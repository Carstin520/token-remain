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

    @Test("Duplicate cached model windows cross devices only once")
    func deduplicatesScopedWindowsBeforeSync() throws {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let oldFable = ScopedQuotaWindow(
            scopeID: "fable",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: now + 60)
        )
        let latestFable = ScopedQuotaWindow(
            scopeID: "FABLE",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 63, windowMinutes: 10_080, resetsAt: now + 120)
        )
        func quota(scopedWindows: [ScopedQuotaWindow]) -> ProviderQuota {
            ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now + 300),
                secondary: QuotaWindow(usedPercent: 15, windowMinutes: 10_080, resetsAt: now + 600),
                planName: nil,
                capturedAt: now,
                scopedWindows: scopedWindows
            )
        }

        let duplicated = quota(scopedWindows: [oldFable, latestFable])
        let canonical = quota(scopedWindows: [latestFable])
        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: [.claude: duplicated],
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )
        let syncedFable = try #require(snapshot.providers.first?.scopedWindows)

        #expect(syncedFable.count == 1)
        #expect(syncedFable.first?.scopeID == "fable")
        #expect(syncedFable.first?.window.usedPercent == 63)
        #expect(SyncContentFingerprint.make(
            quotas: [.claude: duplicated],
            history: nil,
            includesUsageHistory: false
        ) == SyncContentFingerprint.make(
            quotas: [.claude: canonical],
            history: nil,
            includesUsageHistory: false
        ))
    }

    @Test("A terminal-damaged scoped label cannot block the complete snapshot")
    func dropsDamagedScopedWindowBeforeSync() throws {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let valid = ScopedQuotaWindow(
            scopeID: "fable",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: now + 120)
        )
        let damaged = ScopedQuotaWindow(
            scopeID: "fable_40_used_resets_aug14_at_12",
            displayName: "Fable\n████████████████████    40%used\nResets Aug14 at 12:59pm(Asia/Shanghai",
            window: QuotaWindow(usedPercent: 0, windowMinutes: 10_080, resetsAt: now + 120)
        )
        func quota(scopedWindows: [ScopedQuotaWindow]) -> ProviderQuota {
            ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now + 60),
                secondary: QuotaWindow(usedPercent: 22, windowMinutes: 10_080, resetsAt: now + 600),
                planName: nil,
                capturedAt: now,
                scopedWindows: scopedWindows
            )
        }

        let polluted = quota(scopedWindows: [valid, damaged])
        let canonical = quota(scopedWindows: [valid])
        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: [.claude: polluted],
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )

        #expect(snapshot.providers.first?.scopedWindows?.map(\.scopeID) == ["fable"])
        #expect(throws: Never.self) {
            try snapshot.validatedForTransport(configuration: .current(now: now))
        }
        #expect(SyncContentFingerprint.make(
            quotas: [.claude: polluted],
            history: nil,
            includesUsageHistory: false
        ) == SyncContentFingerprint.make(
            quotas: [.claude: canonical],
            history: nil,
            includesUsageHistory: false
        ))
    }

    @Test("Pool names cross devices sanitized; account-like labels drop to nil")
    func poolNamesCrossSanitized() throws {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        let quota = ProviderQuota(
            provider: .cursor,
            primary: QuotaWindow(
                usedPercent: 41,
                windowMinutes: 43_200,
                resetsAt: now + 600,
                poolName: "Cursor Models"
            ),
            secondary: QuotaWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: now + 300,
                // 不合格的池名只丢标签,不丢窗口、更不拒收快照。
                poolName: "user@example.com"
            ),
            planName: nil,
            capturedAt: now
        )
        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: [.cursor: quota],
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )
        let windows = try #require(snapshot.providers.first?.windows)

        #expect(windows.map(\.poolName) == ["Cursor Models", nil])
        #expect(throws: Never.self) {
            try snapshot.validatedForTransport(configuration: .current(now: now))
        }

        // Round-trip through the wire codec keeps the surviving label.
        let decoded = try MobileUsageSnapshot.decodedPayload(from: snapshot.encodedPayload())
        #expect(decoded.providers.first?.windows.first?.poolName == "Cursor Models")
    }

    @Test("A provider with more windows than the wire budget is truncated, not rejected")
    func overflowingScopedWindowsAreTruncatedDeterministically() throws {
        let now = Date(timeIntervalSince1970: 1_784_764_800)
        // 4 个模型池 × (session, weekly) = 8 条 scoped,加上账户级 2 窗共
        // 10,超出 maximumWindowsPerProvider(8)。整份快照绝不能因此
        // 拒收:按服务端语义顺序保序截尾。
        let scoped = (1...4).flatMap { index -> [ScopedQuotaWindow] in
            [
                ScopedQuotaWindow(
                    scopeID: "pool\(index)_session",
                    displayName: "Model Pool \(index)",
                    window: QuotaWindow(usedPercent: Double(index), windowMinutes: 300, resetsAt: now + 600)
                ),
                ScopedQuotaWindow(
                    scopeID: "pool\(index)_weekly",
                    displayName: "Model Pool \(index)",
                    window: QuotaWindow(usedPercent: Double(index * 10), windowMinutes: 10_080, resetsAt: now + 600)
                )
            ]
        }
        func quota(scopedWindows: [ScopedQuotaWindow]) -> ProviderQuota {
            ProviderQuota(
                provider: .codex,
                primary: QuotaWindow(usedPercent: 31, windowMinutes: 300, resetsAt: now + 600),
                secondary: QuotaWindow(usedPercent: 22, windowMinutes: 10_080, resetsAt: now + 900),
                planName: nil,
                capturedAt: now,
                scopedWindows: scopedWindows
            )
        }

        let snapshot = MobileSnapshotRedactor.makeSnapshot(
            from: [.codex: quota(scopedWindows: scoped)],
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now
        )
        let provider = try #require(snapshot.providers.first)

        // Exactly at the validation cap, first six scoped rows kept in order.
        #expect(provider.windows.count == 2)
        #expect(provider.scopedWindows?.count == 6)
        #expect(provider.windows.count + (provider.scopedWindows?.count ?? 0)
            == MobileSnapshotRedactor.maximumSyncedWindowsPerProvider)
        #expect(provider.scopedWindows?.map(\.scopeID) == [
            "pool1_session", "pool1_weekly",
            "pool2_session", "pool2_weekly",
            "pool3_session", "pool3_weekly"
        ])
        #expect(throws: Never.self) {
            try snapshot.validatedForTransport(configuration: .current(now: now))
        }

        // The fingerprint mirrors the truncation: a change confined to the
        // dropped tail must not trigger a re-upload of an identical payload.
        #expect(SyncContentFingerprint.make(
            quotas: [.codex: quota(scopedWindows: scoped)],
            history: nil,
            includesUsageHistory: false
        ) == SyncContentFingerprint.make(
            quotas: [.codex: quota(scopedWindows: Array(scoped.prefix(6)))],
            history: nil,
            includesUsageHistory: false
        ))
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

        #expect(snapshot.providers.count == SyncedProviderID.supportedOnCurrentMobile.count)
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
                    agents: [
                        .init(
                            id: "claude",
                            tokens: 12_000_000,
                            cost: 22.5,
                            models: [
                                .init(
                                    id: "private-model-alias",
                                    inputTokens: 12_000_000,
                                    outputTokens: 0,
                                    cacheTokens: 0,
                                    cost: 22.5
                                )
                            ]
                        ),
                        .init(id: "codex", tokens: 7_000_000, cost: 9.75)
                    ]
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
        #expect(synced.sourceDay != nil)

        let payload = try on.encodedPayload()
        let text = try #require(String(data: payload, encoding: .utf8))
        for deniedField in ["prompt", "project", "session", "account", "path", "request"] {
            #expect(!text.lowercased().contains(deniedField))
        }
        #expect(!text.contains("modelBreakdowns"))
        #expect(!text.contains("models"))
        #expect(!text.contains("private-model-alias"))
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

        let synced = try #require(snapshot.dailyUsageHistory)
        #expect(synced.days.map(\.day) == [
            "2026-07-22",
            "2026-07-23"
        ])
        #expect(synced.sourceDay.map { key in synced.days.contains { $0.day == key } } == true)
    }

    @Test("Every macOS provider has a well-formed stable wire identifier")
    func stableProviderIdentifiers() {
        let identifiers = ProviderQuota.Provider.displayOrder.map(MobileSnapshotRedactor.stableID)
        #expect(Set(identifiers).count == ProviderQuota.Provider.displayOrder.count)
        #expect(identifiers.allSatisfy(SyncedProviderID.isWellFormed))
        #expect(SyncedProviderID.supportedOnCurrentMobile.isSubset(of: Set(identifiers)))
        // Older phone builds safely filter the two newly introduced provider
        // IDs until their presentation layer ships corresponding cards.
        #expect(!SyncedProviderID.supportedOnCurrentMobile.contains("zaiteam"))
        #expect(!SyncedProviderID.supportedOnCurrentMobile.contains("thirdparty"))
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
