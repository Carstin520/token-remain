import Foundation
import Testing
import TokenRemainKit
import TokenRemainSyncKit
@testable import TokenRemain

private actor FakeCloudStore: SyncCloudSnapshotStoring {
    var stored: SyncCloudStoredEnvelope?
    var status: SyncCloudAccountStatus = .available
    private(set) var subscriptionEnsured = false

    init(stored: SyncCloudStoredEnvelope?) { self.stored = stored }

    func accountStatus() async throws -> SyncCloudAccountStatus { status }
    func ensureZone() async throws {}
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

        #expect(await client.pull(now: now) == .updated(fixture.snapshot))
        #expect(await client.pull(now: now) == .noChange(.duplicate))
        #expect(await keys.loadOrCreateCalls == 0)
        #expect(await cloud.subscriptionEnsured)
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

        #expect(await client.pull(now: now) == .updated(first.snapshot))
        await cloud.replace(with: nil)
        #expect(await client.pull(now: now) == .noChange(.noRemoteSnapshot))
        await cloud.replace(with: replacement.stored)
        #expect(await client.pull(now: now) == .updated(replacement.snapshot))
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

        #expect(await client.pull(now: now) == .updated(first.snapshot))
        await cloud.replace(with: second.stored)
        guard case .requiresSourceConfirmation(let candidate) = await client.pull(now: now) else {
            Issue.record("A new source must not be accepted implicitly")
            return
        }
        #expect(candidate.marker.sourceInstanceID == second.snapshot.sourceInstanceID)
        #expect(await client.pull(
            confirmedSourceChange: candidate.marker,
            now: now
        ) == .updated(second.snapshot))
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

        #expect(await client.pull(now: now) == .updated(first.snapshot))
        await cloud.replace(with: second.stored)
        guard case .requiresSourceConfirmation(let candidate) = await client.pull(now: now) else {
            Issue.record("The second source must require confirmation")
            return
        }

        await cloud.replace(with: replacement.stored)
        guard case .requiresSourceConfirmation(let newCandidate) = await client.pull(
            confirmedSourceChange: candidate.marker,
            now: now
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
        return (snapshot, key, try CloudKitSyncRecordCodec.storedEnvelope(from: record))
    }

    private func makeClaudeQuota() -> SyncedProviderQuota {
        SyncedProviderQuota(
            providerID: SyncedProviderID.claude,
            windows: [SyncedQuotaWindow(usedPercent: 42, windowMinutes: 300, resetsAt: now + 300)],
            capturedAt: now,
            statusCode: .available
        )
    }

    private func uniqueSuite() -> String { "TokenRemainSyncTests.\(UUID().uuidString)" }
}
