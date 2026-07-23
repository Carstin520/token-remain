import Foundation
import Testing
import TokenRemainKit
import TokenRemainSyncKit
@testable import TokenRemain

private actor FakeCloudStore: SyncCloudSnapshotStoring {
    var stored: SyncCloudStoredEnvelope?
    var status: SyncCloudAccountStatus
    var operationError: SyncCloudStoreError?
    private(set) var subscriptionEnsured = false

    init(
        stored: SyncCloudStoredEnvelope?,
        status: SyncCloudAccountStatus = .available,
        operationError: SyncCloudStoreError? = nil
    ) {
        self.stored = stored
        self.status = status
        self.operationError = operationError
    }

    func accountStatus() async throws -> SyncCloudAccountStatus { status }
    func ensureZone() async throws {
        if let operationError { throw operationError }
    }
    func save(_ envelope: EncryptedSyncEnvelope) async throws {}
    func fetch() async throws -> SyncCloudStoredEnvelope? { stored }
    func deleteCurrent() async throws {}
    func deleteZone() async throws {}
    func ensureSubscription() async throws { subscriptionEnsured = true }
    func replace(with value: SyncCloudStoredEnvelope?) { stored = value }
}

private actor FakeKeyStore: SyncKeyStoring {
    var records: [UUID: SyncKeyRecord]
    private(set) var loadOrCreateCalls = 0

    init(records: [UUID: SyncKeyRecord]) { self.records = records }

    func current() async throws -> SyncKeyRecord? { records.values.first }
    func load(keyID: UUID) async throws -> SyncKeyRecord? { records[keyID] }
    func loadOrCreate() async throws -> SyncKeyRecord {
        loadOrCreateCalls += 1
        return records.values.first!
    }
    func rotate() async throws -> SyncKeyRecord { records.values.first! }
    func delete(keyID: UUID) async throws { records[keyID] = nil }
    func deleteAll() async throws { records = [:] }
}

@Suite("iPhone private sync client")
struct MobileSyncClientTests {
    private let now = Date(timeIntervalSince1970: 1_784_764_800)
    private let containerID = MobileSyncClient.defaultContainerIdentifier

    @Test("A fresh installation enables private Mac sync without setup")
    func freshInstallDefaultsToMacSync() {
        let suite = uniqueSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = TRSettingsStore(suiteName: suite)

        #expect(settings.origin == .macSync)
        settings.origin = .none
        #expect(settings.origin == .none)
    }

    @Test("Automatic health checks use fast retries before steady reconciliation")
    func automaticRetryPolicy() {
        let expected: [TimeInterval] = [2, 5, 10, 30, 60, 45, 45]
        for (attempt, delay) in expected.enumerated() {
            #expect(MobileSyncHealthPolicy.retryDelay(
                afterAttempt: attempt,
                state: .waitingForKey
            ) == delay)
        }
        #expect(MobileSyncHealthPolicy.retryDelay(
            afterAttempt: 0,
            state: .synced(now)
        ) == 45)
    }

    @Test("Only persistent actionable states produce setup guidance")
    func actionableHealthGuidance() {
        #expect(MobileSyncHealthPolicy.guidance(for: .waitingForMac) == .openMac)
        #expect(MobileSyncHealthPolicy.graceInterval(for: .openMac) == 120)
        #expect(MobileSyncHealthPolicy.guidance(for: .waitingForKey) == .checkKeychain)
        #expect(MobileSyncHealthPolicy.graceInterval(for: .checkKeychain) == 120)
        #expect(MobileSyncHealthPolicy.guidance(
            for: .failed(.iCloudAccountUnavailable)
        ) == .checkICloud)
        #expect(MobileSyncHealthPolicy.guidance(
            for: .failed(.networkUnavailable)
        ) == nil)
    }

    @Test("A valid snapshot updates once and a duplicate never overwrites")
    func updateThenDuplicate() async throws {
        let fixture = try makeFixture(source: UUID(), sequence: 1)
        let cloud = FakeCloudStore(stored: fixture.stored)
        let keys = FakeKeyStore(records: [fixture.key.keyID: fixture.key])
        let suite = uniqueSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let client = MobileSyncClient(
            cloudStore: cloud,
            keyStore: keys,
            containerIdentifier: containerID,
            defaultsSuiteName: suite
        )

        #expect(await client.pull(now: now, phoneReceivedAt: now) == .updated(delivery(fixture.snapshot)))
        #expect(await client.pull(now: now, phoneReceivedAt: now) == .noChange(.duplicate))
        #expect(await keys.loadOrCreateCalls == 0)
        #expect(await cloud.subscriptionEnsured)
    }

    @Test("Every unavailable iCloud account state fails before reading a snapshot")
    func unavailableICloudAccounts() async {
        let cases: [(SyncCloudAccountStatus, MobileSyncFailure)] = [
            (.noAccount, .iCloudAccountUnavailable),
            (.restricted, .iCloudAccountRestricted),
            (.temporarilyUnavailable, .iCloudTemporarilyUnavailable),
            (.couldNotDetermine, .iCloudAccountUnknown)
        ]

        for (status, expected) in cases {
            let cloud = FakeCloudStore(stored: nil, status: status)
            let client = MobileSyncClient(
                cloudStore: cloud,
                keyStore: FakeKeyStore(records: [:]),
                containerIdentifier: containerID,
                defaultsSuiteName: uniqueSuite()
            )
            #expect(await client.pull(now: now) == .failed(expected))
            #expect(await cloud.subscriptionEnsured == false)
        }
    }

    @Test("Network, authentication, permission, rate-limit, and missing-record errors stay redacted")
    func cloudFailuresAreRedacted() async {
        let cases: [(SyncCloudStoreError, MobileSyncFailure)] = [
            (.networkUnavailable, .networkUnavailable),
            (.notAuthenticated, .iCloudAuthenticationRequired),
            (.permissionDenied, .iCloudPermissionDenied),
            (.serviceUnavailable, .serviceUnavailable),
            (.requestRateLimited(retryAfterSeconds: 42), .rateLimited(retryAfterSeconds: 42)),
            (.conflict, .syncConflict),
            (.recordNotFound, .remoteRecordUnavailable),
            (.zoneNotFound, .remoteRecordUnavailable),
            (.malformedRecord(.invalidEnvelope), .untrustedRemotePayload)
        ]

        for (error, expected) in cases {
            let cloud = FakeCloudStore(stored: nil, operationError: error)
            let client = MobileSyncClient(
                cloudStore: cloud,
                keyStore: FakeKeyStore(records: [:]),
                containerIdentifier: containerID,
                defaultsSuiteName: uniqueSuite()
            )
            #expect(await client.pull(now: now) == .failed(expected))
        }
    }

    @Test("Missing and incorrect keys fail closed without creating a receiver key")
    func keyFailure() async throws {
        let fixture = try makeFixture(source: UUID(), sequence: 1)
        let cloud = FakeCloudStore(stored: fixture.stored)
        let emptyKeys = FakeKeyStore(records: [:])
        let missingClient = MobileSyncClient(
            cloudStore: cloud,
            keyStore: emptyKeys,
            containerIdentifier: containerID,
            defaultsSuiteName: uniqueSuite()
        )
        #expect(await missingClient.pull(now: now) == .failed(.syncKeyUnavailable))
        #expect(await emptyKeys.loadOrCreateCalls == 0)

        let wrongKey = try SyncKeyRecord(keyID: fixture.key.keyID, key: .random())
        let wrongKeys = FakeKeyStore(records: [wrongKey.keyID: wrongKey])
        let wrongClient = MobileSyncClient(
            cloudStore: cloud,
            keyStore: wrongKeys,
            containerIdentifier: containerID,
            defaultsSuiteName: uniqueSuite()
        )
        #expect(await wrongClient.pull(now: now) == .failed(.untrustedRemotePayload))
        #expect(await wrongKeys.loadOrCreateCalls == 0)
    }

    @Test("Remote deletion clears the replay epoch")
    func remoteDeletionResetsReplayState() async throws {
        let first = try makeFixture(source: UUID(), sequence: 8)
        let replacement = try makeFixture(source: UUID(), sequence: 1, key: first.key)
        let cloud = FakeCloudStore(stored: first.stored)
        let keys = FakeKeyStore(records: [first.key.keyID: first.key])
        let suite = uniqueSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let client = MobileSyncClient(
            cloudStore: cloud,
            keyStore: keys,
            containerIdentifier: containerID,
            defaultsSuiteName: suite
        )

        #expect(await client.pull(now: now, phoneReceivedAt: now) == .updated(delivery(first.snapshot)))
        await cloud.replace(with: nil)
        #expect(await client.pull(now: now, phoneReceivedAt: now) == .noChange(.noRemoteSnapshot))
        await cloud.replace(with: replacement.stored)
        #expect(await client.pull(now: now, phoneReceivedAt: now) == .updated(delivery(replacement.snapshot)))
    }

    @Test("An older sequence never replaces an accepted snapshot")
    func olderSequenceIsRejected() async throws {
        let source = UUID()
        let latest = try makeFixture(source: source, sequence: 8)
        let older = try makeFixture(source: source, sequence: 7, key: latest.key)
        let cloud = FakeCloudStore(stored: latest.stored)
        let keys = FakeKeyStore(records: [latest.key.keyID: latest.key])
        let suite = uniqueSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let client = MobileSyncClient(
            cloudStore: cloud,
            keyStore: keys,
            containerIdentifier: containerID,
            defaultsSuiteName: suite
        )

        #expect(await client.pull(now: now, phoneReceivedAt: now) == .updated(delivery(latest.snapshot)))
        await cloud.replace(with: older.stored)
        #expect(await client.pull(now: now, phoneReceivedAt: now) == .noChange(.olderSequence))
    }

    @Test("A disabled mobile sync setting rejects delayed data and erases local copies")
    @MainActor
    func disabledSyncRejectsDelayedDataAndErases() {
        let settings = TRSettingsStore.shared
        let previousOrigin = settings.origin
        defer {
            settings.origin = previousOrigin
            SnapshotStore.shared.clear()
            SnapshotHistoryStore.shared.clear()
            MobileDailyUsageHistoryStore.shared.clear()
            MobileCuratedFeedStore.shared.clear()
        }
        settings.origin = .none
        SnapshotStore.shared.clear()
        SnapshotHistoryStore.shared.clear()
        MobileDailyUsageHistoryStore.shared.clear()
        MobileCuratedFeedStore.shared.clear()

        let model = AppModel(arguments: ["TokenRemainTests", "-tr-origin-none"])
        let delayed = MobileUsageSnapshot(
            sourceInstanceID: UUID(),
            sequence: 1,
            generatedAt: now,
            expiresAt: now + 600,
            providers: [makeClaudeQuota()]
        )
        model.applySyncedSnapshot(delayed, now: now)
        #expect(model.origin == .none)
        #expect(model.snapshot.origin == .none)
        #expect(SnapshotStore.shared.read()?.origin != .macSync)

        settings.origin = .macSync
        let enabledModel = AppModel(arguments: ["TokenRemainTests"])
        enabledModel.applySyncedSnapshot(delayed, now: now)
        #expect(SnapshotStore.shared.read()?.origin == .macSync)
        #expect(!SnapshotHistoryStore.shared.load().isEmpty)

        enabledModel.setMacSyncEnabled(false)
        #expect(enabledModel.origin == .none)
        #expect(enabledModel.snapshot.origin == .none)
        #expect(SnapshotStore.shared.read() == nil)
        #expect(SnapshotHistoryStore.shared.load().isEmpty)
        #expect(enabledModel.dailyUsageHistory == nil)
        #expect(enabledModel.curatedFeed == nil)
    }

    @Test("Decrypted daily history persists only in the main app store and clears cleanly")
    func dailyHistoryPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenRemainDailyHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileDailyUsageHistoryStore(directory: directory)
        let history = SyncedDailyUsageHistory(
            days: [
                SyncedDailyUsageDay(
                    day: "2026-07-20",
                    claudeTokens: 10,
                    claudeCost: 1.2,
                    codexTokens: 20,
                    codexCost: 2.4
                ),
                SyncedDailyUsageDay(
                    day: "2026-07-21",
                    claudeTokens: 11,
                    claudeCost: 1.3,
                    codexTokens: 21,
                    codexCost: 2.5
                )
            ],
            capturedAt: now
        )

        store.replace(with: history, now: now)
        #expect(store.load(now: now) == history)
        store.clear()
        #expect(store.load(now: now) == nil)
    }

    @Test("Decrypted curated posts persist only in the main app store and clear cleanly")
    func curatedFeedPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenRemainCuratedFeedTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileCuratedFeedStore(directory: directory)
        let feed = SyncedCuratedFeed(
            posts: [
                SyncedCuratedPost(
                    id: "1234567890123456789",
                    username: "OpenAI",
                    displayName: "OpenAI",
                    text: "Public update",
                    createdAt: now - 60,
                    url: URL(string: "https://x.com/OpenAI/status/1234567890123456789")!,
                    priority: .majorUpdate
                )
            ],
            capturedAt: now
        )

        store.replace(with: feed, now: now)
        #expect(store.load(now: now) == feed)
        store.clear()
        #expect(store.load(now: now) == nil)
    }

    @Test("A second Mac source requires explicit confirmation")
    func sourceChangeConfirmation() async throws {
        let first = try makeFixture(source: UUID(), sequence: 1)
        let second = try makeFixture(source: UUID(), sequence: 1, key: first.key)
        let cloud = FakeCloudStore(stored: first.stored)
        let keys = FakeKeyStore(records: [first.key.keyID: first.key])
        let client = MobileSyncClient(
            cloudStore: cloud,
            keyStore: keys,
            containerIdentifier: containerID,
            defaultsSuiteName: uniqueSuite()
        )

        #expect(await client.pull(now: now, phoneReceivedAt: now) == .updated(delivery(first.snapshot)))
        await cloud.replace(with: second.stored)
        guard case .requiresSourceConfirmation(let candidate) = await client.pull(
            now: now,
            phoneReceivedAt: now
        ) else {
            Issue.record("A new source must not be accepted implicitly")
            return
        }
        #expect(candidate.marker.sourceInstanceID == second.snapshot.sourceInstanceID)
        #expect(await client.pull(
            confirmedSourceChange: candidate.marker,
            now: now,
            phoneReceivedAt: now
        ) == .updated(delivery(second.snapshot)))
    }

    @Test("Source confirmation is bound to the exact authenticated candidate")
    func sourceChangeConfirmationRejectsReplacement() async throws {
        let first = try makeFixture(source: UUID(), sequence: 1)
        let second = try makeFixture(source: UUID(), sequence: 1, key: first.key)
        let replacement = try makeFixture(source: UUID(), sequence: 1, key: first.key)
        let cloud = FakeCloudStore(stored: first.stored)
        let keys = FakeKeyStore(records: [first.key.keyID: first.key])
        let client = MobileSyncClient(
            cloudStore: cloud,
            keyStore: keys,
            containerIdentifier: containerID,
            defaultsSuiteName: uniqueSuite()
        )

        #expect(await client.pull(now: now, phoneReceivedAt: now) == .updated(delivery(first.snapshot)))
        await cloud.replace(with: second.stored)
        guard case .requiresSourceConfirmation(let candidate) = await client.pull(
            now: now,
            phoneReceivedAt: now
        ) else {
            Issue.record("The second source must require confirmation")
            return
        }

        await cloud.replace(with: replacement.stored)
        guard case .requiresSourceConfirmation(let newCandidate) = await client.pull(
            confirmedSourceChange: candidate.marker,
            now: now,
            phoneReceivedAt: now
        ) else {
            Issue.record("A replacement source must not inherit confirmation")
            return
        }
        #expect(newCandidate.marker.sourceInstanceID == replacement.snapshot.sourceInstanceID)
    }

    @Test("The adapter renders every known provider and ignores unknown or offline values")
    func adapterBoundary() throws {
        let future = SyncedProviderQuota(
            providerID: "future-provider",
            windows: [SyncedQuotaWindow(usedPercent: 1, windowMinutes: 60, resetsAt: nil)],
            capturedAt: now,
            statusCode: .available
        )
        let offline = SyncedProviderQuota(
            providerID: SyncedProviderID.codex,
            windows: [SyncedQuotaWindow(usedPercent: 2, windowMinutes: 60, resetsAt: nil)],
            capturedAt: now,
            statusCode: .offline
        )
        let cursor = SyncedProviderQuota(
            providerID: SyncedProviderID.cursor,
            windows: [SyncedQuotaWindow(usedPercent: 1.5, windowMinutes: 44_640, resetsAt: now + 600)],
            capturedAt: now,
            statusCode: .available,
            planName: "Pro Plus"
        )
        let antigravity = SyncedProviderQuota(
            providerID: SyncedProviderID.antigravity,
            windows: [SyncedQuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: now + 300)],
            capturedAt: now,
            statusCode: .available
        )
        let source = MobileUsageSnapshot(
            sourceInstanceID: UUID(), sequence: 1, generatedAt: now, expiresAt: now + 600,
            providers: [makeClaudeQuota(), cursor, antigravity, future, offline]
        )
        let result = MobileSnapshotAdapter.usageSnapshot(from: source)

        #expect(result.origin == .macSync)
        #expect(result.providers.map(\.provider) == [.claude, .cursor, .antigravity])
        #expect(result.providers[0].planName == nil)
        #expect(result.providers[1].planName == "Pro Plus")
        #expect(result.dailyTokens == nil)
    }

    private func makeFixture(
        source: UUID,
        sequence: UInt64,
        key existingKey: SyncKeyRecord? = nil
    ) throws -> (snapshot: MobileUsageSnapshot, key: SyncKeyRecord, stored: SyncCloudStoredEnvelope) {
        let key = try existingKey ?? SyncKeyRecord(keyID: UUID(), key: .random())
        let snapshot = MobileUsageSnapshot(
            sourceInstanceID: source,
            sequence: sequence,
            generatedAt: now,
            expiresAt: now + 600,
            providers: [makeClaudeQuota()]
        )
        let envelope = try EncryptedSyncEnvelope.seal(
            snapshot,
            using: key.key,
            keyID: key.keyID,
            containerID: containerID,
            configuration: .current(now: now)
        )
        let record = try CloudKitSyncRecordCodec.record(for: envelope)
        let decoded = try CloudKitSyncRecordCodec.storedEnvelope(from: record)
        return (
            snapshot,
            key,
            SyncCloudStoredEnvelope(
                envelope: decoded.envelope,
                metadata: decoded.metadata,
                macUploadedAt: now
            )
        )
    }

    private func makeClaudeQuota() -> SyncedProviderQuota {
        SyncedProviderQuota(
            providerID: SyncedProviderID.claude,
            windows: [SyncedQuotaWindow(usedPercent: 42, windowMinutes: 300, resetsAt: now + 300)],
            capturedAt: now,
            statusCode: .available
        )
    }

    private func delivery(_ snapshot: MobileUsageSnapshot) -> MobileSyncDelivery {
        MobileSyncDelivery(
            snapshot: snapshot,
            macUploadedAt: now,
            phoneReceivedAt: now
        )
    }

    private func uniqueSuite() -> String { "TokenRemainSyncTests.\(UUID().uuidString)" }
}
