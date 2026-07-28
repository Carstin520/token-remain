@preconcurrency import CloudKit
import Foundation
import Testing
@testable import TokenRemainSyncKit

private let storageNow = Date(timeIntervalSince1970: 1_784_764_800) // 2026-07-22T00:00:00Z
private let storageConfiguration = SyncValidationConfiguration(now: storageNow)
private let storageSourceID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
private let storageKeyID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
private let storageContainerID = "iCloud.com.jamesli.tokenremain"

private struct StorageResultError: Error {}

private func storageEnvelope(
    sourceInstanceID: UUID = storageSourceID,
    sequence: UInt64 = 1
) throws -> EncryptedSyncEnvelope {
    let snapshot = MobileUsageSnapshot(
        sourceInstanceID: sourceInstanceID,
        sequence: sequence,
        generatedAt: storageNow,
        expiresAt: storageNow + 15 * 60,
        providers: [
            SyncedProviderQuota(
                providerID: SyncedProviderID.codex,
                windows: [SyncedQuotaWindow(usedPercent: 23.5, windowMinutes: 300, resetsAt: storageNow + 9_000)],
                capturedAt: storageNow,
                statusCode: .available
            )
        ]
    )
    return try EncryptedSyncEnvelope.seal(
        snapshot,
        using: SyncEncryptionKey(rawValue: Data(repeating: 5, count: SyncEncryptionKey.byteCount)),
        keyID: storageKeyID,
        containerID: storageContainerID,
        configuration: storageConfiguration
    )
}

private func storageStoredEnvelope(
    sourceInstanceID: UUID = storageSourceID,
    sequence: UInt64
) throws -> SyncCloudStoredEnvelope {
    let envelope = try storageEnvelope(
        sourceInstanceID: sourceInstanceID,
        sequence: sequence
    )
    return SyncCloudStoredEnvelope(
        envelope: envelope,
        metadata: SyncCloudRecordMetadata(
            envelopeVersion: envelope.envelopeVersion,
            keyID: envelope.keyID,
            sourceInstanceID: envelope.sourceInstanceID,
            sequence: envelope.sequence,
            generatedAt: envelope.generatedAt
        )
    )
}

private actor InMemorySynchronizableKeychain: SynchronizableKeychainClient {
    private var values: [String: Data] = [:]

    func read(account: String) async throws -> Data? {
        values[account]
    }

    func write(_ data: Data, account: String) async throws {
        values[account] = data
    }

    func delete(account: String?) async throws {
        if let account {
            values.removeValue(forKey: account)
        } else {
            values.removeAll()
        }
    }

    func inject(_ data: Data, account: String) {
        values[account] = data
    }
}

@Suite("Cross-device sync storage foundations")
struct SyncStorageFoundationTests {
    @Test("Key records require a non-zero ID and exactly 32 bytes")
    func keyRecordValidation() throws {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let validRawKey = Data(repeating: 1, count: SyncEncryptionKey.byteCount)
        #expect(throws: SyncKeyStoreError.invalidKeyID) {
            try SyncKeyRecord(keyID: zero, rawKey: validRawKey)
        }
        #expect(throws: SyncKeyStoreError.invalidKeyMaterial(31)) {
            try SyncKeyRecord(keyID: storageKeyID, rawKey: Data(repeating: 1, count: 31))
        }
    }

    @Test("Load-or-create, rotation, and deletion use only the injected sync-key store")
    func keyStoreLifecycle() async throws {
        let memory = InMemorySynchronizableKeychain()
        let store = SynchronizableSyncKeyStore(client: memory)

        #expect(try await store.current() == nil)
        let first = try await store.loadOrCreate()
        #expect(first.key.rawValue.count == SyncEncryptionKey.byteCount)
        #expect(try await store.current() == first)
        #expect(try await store.load(keyID: first.keyID) == first)

        let second = try await store.rotate()
        #expect(second.keyID != first.keyID)
        #expect(try await store.current() == second)
        // Rotation preserves the old key for an in-flight CloudKit record.
        #expect(try await store.load(keyID: first.keyID) == first)

        try await store.delete(keyID: second.keyID)
        #expect(try await store.current() == nil)
        try await store.deleteAll()
        #expect(try await store.load(keyID: first.keyID) == nil)
    }

    @Test("A malformed current pointer fails closed instead of minting a replacement key")
    func malformedKeyPointerFailsClosed() async throws {
        let memory = InMemorySynchronizableKeychain()
        await memory.inject(Data("not-a-uuid".utf8), account: "current-v1")
        let store = SynchronizableSyncKeyStore(client: memory)

        await #expect(throws: SyncKeyStoreError.malformedCurrentPointer) {
            try await store.loadOrCreate()
        }
    }

    @Test("CloudKit record round-trip contains only opaque data and allowlisted metadata")
    func recordRoundTripAndAllowlist() throws {
        let envelope = try storageEnvelope()
        let record = try CloudKitSyncRecordCodec.record(for: envelope)

        #expect(record.recordType == CloudKitSyncRecordCodec.recordType)
        #expect(record.recordID == CloudKitSyncRecordCodec.currentRecordID())
        let encryptedKeys = Set(record.encryptedValues.allKeys())
        #expect(Set(record.allKeys()).subtracting(encryptedKeys) == Set([
            CloudKitSyncRecordCodec.envelopeVersionField,
            CloudKitSyncRecordCodec.keyIDField,
            CloudKitSyncRecordCodec.sourceInstanceIDField,
            CloudKitSyncRecordCodec.sequenceField,
            CloudKitSyncRecordCodec.generatedAtField
        ]))
        #expect(encryptedKeys == [CloudKitSyncRecordCodec.encryptedEnvelopeField])
        #expect(record.encryptedValues[CloudKitSyncRecordCodec.encryptedEnvelopeField] is Data)
        #expect(record[CloudKitSyncRecordCodec.encryptedEnvelopeField] == nil)
        #expect(record["providers"] == nil)
        #expect(record["quota"] == nil)

        let decoded = try CloudKitSyncRecordCodec.storedEnvelope(from: record)
        #expect(decoded.envelope == envelope)
        #expect(decoded.metadata.sequence == envelope.sequence)
        #expect(decoded.metadata.keyID == envelope.keyID)
    }

    @Test("Upsert reuses a fetched record, clears unexpected fields, and writes the next envelope")
    func recordOverwriteIsAllowlisted() throws {
        let first = try storageEnvelope(sequence: 1)
        let second = try storageEnvelope(sequence: 2)
        let fetchedRecord = try CloudKitSyncRecordCodec.record(for: first)
        fetchedRecord["legacyUnexpectedField"] = "must be removed" as NSString
        fetchedRecord.encryptedValues["legacyEncryptedField"] = "must be removed" as NSString

        try CloudKitSyncRecordCodec.overwrite(fetchedRecord, with: second)
        #expect(fetchedRecord["legacyUnexpectedField"] == nil)
        #expect(fetchedRecord.encryptedValues["legacyEncryptedField"] == nil)
        #expect(try CloudKitSyncRecordCodec.storedEnvelope(from: fetchedRecord).envelope == second)
    }

    @Test("Each Mac source uses one canonical record ID in the existing zone and type")
    func sourceRecordRoundTrip() throws {
        let envelope = try storageEnvelope(sequence: 7)
        let record = try CloudKitSyncRecordCodec.sourceRecord(for: envelope)

        #expect(record.recordType == CloudKitSyncRecordCodec.recordType)
        #expect(record.recordID == CloudKitSyncRecordCodec.sourceRecordID(for: storageSourceID))
        #expect(record.recordID.recordName == "source-v2-\(storageSourceID.uuidString.lowercased())")
        #expect(try CloudKitSyncRecordCodec.recordKind(for: record.recordID) == .source(storageSourceID))
        #expect(try CloudKitSyncRecordCodec.storedEnvelope(from: record).envelope == envelope)

        let otherSource = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        let mismatchedRecord = CKRecord(
            recordType: CloudKitSyncRecordCodec.recordType,
            recordID: CloudKitSyncRecordCodec.sourceRecordID(for: otherSource)
        )
        #expect(throws: SyncCloudRecordValidationError.metadataMismatch(
            CloudKitSyncRecordCodec.sourceInstanceIDField
        )) {
            try CloudKitSyncRecordCodec.overwrite(mismatchedRecord, with: envelope)
        }
    }

    @Test("Source record names fail closed when the device ID is malformed or noncanonical")
    func sourceRecordNameValidation() throws {
        let zoneID = CloudKitSyncRecordCodec.zoneID()
        let futureRecord = CKRecord.ID(recordName: "future-v3", zoneID: zoneID)
        #expect(try CloudKitSyncRecordCodec.recordKind(for: futureRecord) == nil)

        let malformed = CKRecord.ID(
            recordName: "\(CloudKitSyncRecordCodec.sourceRecordPrefix)not-a-uuid",
            zoneID: zoneID
        )
        #expect(throws: SyncCloudRecordValidationError.unexpectedRecordID) {
            try CloudKitSyncRecordCodec.recordKind(for: malformed)
        }

        let mixedCaseSource = UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")!
        let uppercase = CKRecord.ID(
            recordName: "\(CloudKitSyncRecordCodec.sourceRecordPrefix)\(mixedCaseSource.uuidString)",
            zoneID: zoneID
        )
        #expect(throws: SyncCloudRecordValidationError.unexpectedRecordID) {
            try CloudKitSyncRecordCodec.recordKind(for: uppercase)
        }

        let foreignOwner = CKRecord.ID(
            recordName: CloudKitSyncRecordCodec.sourceRecordName(for: storageSourceID),
            zoneID: CKRecordZone.ID(
                zoneName: CloudKitSyncRecordCodec.zoneName,
                ownerName: "foreign-owner"
            )
        )
        #expect(throws: SyncCloudRecordValidationError.unexpectedRecordID) {
            try CloudKitSyncRecordCodec.recordKind(for: foreignOwner)
        }
    }

    @Test("Same-source upsert accepts only monotonic sequence progress")
    func sourceUpsertSequencePolicy() throws {
        let first = try storageEnvelope(sequence: 4)
        let next = try storageEnvelope(sequence: 5)
        let older = try storageEnvelope(sequence: 3)
        let resealedSameSequence = try storageEnvelope(sequence: 4)
        let otherSource = try storageEnvelope(sourceInstanceID: UUID(), sequence: 5)

        #expect(SyncCloudSourceUpsertPolicy.decision(existing: nil, candidate: first) == .create)
        #expect(SyncCloudSourceUpsertPolicy.decision(existing: first, candidate: first) == .duplicate)
        #expect(SyncCloudSourceUpsertPolicy.decision(existing: first, candidate: next) == .overwrite)
        #expect(SyncCloudSourceUpsertPolicy.decision(existing: first, candidate: older) == .rejectConflict)
        #expect(SyncCloudSourceUpsertPolicy.decision(
            existing: first,
            candidate: resealedSameSequence
        ) == .rejectConflict)
        #expect(SyncCloudSourceUpsertPolicy.decision(
            existing: first,
            candidate: otherSource
        ) == .rejectConflict)
    }

    @Test("Incremental source changes isolate rejected records and preserve tombstones")
    func sourceChangeReduction() throws {
        let otherSource = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        var reducer = SyncCloudSourceChangeReducer()

        reducer.recordChange(try storageStoredEnvelope(sequence: 4))
        reducer.recordChange(try storageStoredEnvelope(sequence: 5))
        reducer.recordChange(try storageStoredEnvelope(sequence: 3))
        reducer.recordChange(try storageStoredEnvelope(sourceInstanceID: otherSource, sequence: 1))
        reducer.recordDeletion(otherSource)
        reducer.recordRejection("source-v2-not-a-uuid")

        #expect(reducer.changedSources.map(\.envelope.sequence) == [5])
        #expect(reducer.deletedSourceInstanceIDs == [otherSource])
        #expect(reducer.rejectedRecordNames == [
            CloudKitSyncRecordCodec.sourceRecordName(for: storageSourceID),
            "source-v2-not-a-uuid",
        ])
    }

    @Test("Missing, oversized, and inconsistent CloudKit fields are rejected before decryption")
    func recordValidationFailures() throws {
        let envelope = try storageEnvelope()

        let missing = try CloudKitSyncRecordCodec.record(for: envelope)
        missing.encryptedValues[CloudKitSyncRecordCodec.encryptedEnvelopeField] = nil
        #expect(throws: SyncCloudRecordValidationError.missingField(CloudKitSyncRecordCodec.encryptedEnvelopeField)) {
            try CloudKitSyncRecordCodec.storedEnvelope(from: missing)
        }

        let oversized = try CloudKitSyncRecordCodec.record(for: envelope)
        oversized.encryptedValues[CloudKitSyncRecordCodec.encryptedEnvelopeField] = Data(
            repeating: 0,
            count: EncryptedSyncEnvelope.maximumEncodedEnvelopeBytes + 1
        ) as NSData
        #expect(throws: SyncCloudRecordValidationError.invalidField(CloudKitSyncRecordCodec.encryptedEnvelopeField)) {
            try CloudKitSyncRecordCodec.storedEnvelope(from: oversized)
        }

        let inconsistent = try CloudKitSyncRecordCodec.record(for: envelope)
        inconsistent[CloudKitSyncRecordCodec.sequenceField] = "999" as NSString
        #expect(throws: SyncCloudRecordValidationError.metadataMismatch(CloudKitSyncRecordCodec.sequenceField)) {
            try CloudKitSyncRecordCodec.storedEnvelope(from: inconsistent)
        }
    }

    @Test("CloudKit errors map to stable redacted retry decisions")
    func cloudErrorMapping() {
        #expect(CloudKitPrivateSnapshotStore.map(code: .networkFailure) == .networkUnavailable)
        #expect(CloudKitPrivateSnapshotStore.map(code: .requestRateLimited, retryAfterSeconds: 12) == .requestRateLimited(retryAfterSeconds: 12))
        #expect(CloudKitPrivateSnapshotStore.map(code: .serverRecordChanged) == .conflict)
        #expect(CloudKitPrivateSnapshotStore.map(code: .unknownItem) == .recordNotFound)
        #expect(CloudKitPrivateSnapshotStore.map(code: .changeTokenExpired) == .changeTokenExpired)
        #expect(CloudKitPrivateSnapshotStore.map(code: .userDeletedZone) == .zoneNotFound)
        #expect(CloudKitPrivateSnapshotStore.map(code: .zoneBusy) == .requestRateLimited(retryAfterSeconds: nil))
        #expect(CloudKitPrivateSnapshotStore.map(code: .serverResponseLost) == .serviceUnavailable)
    }

    @Test("CloudKit zone mutations require a successful per-zone result")
    func zoneMutationResultValidation() throws {
        let zoneID = CloudKitSyncRecordCodec.zoneID()
        let zone = CKRecordZone(zoneID: zoneID)
        #expect(throws: Never.self) {
            try CloudKitPrivateSnapshotStore.validateZoneSaveResult(
                .success(zone),
                zoneID: zoneID
            )
        }
        #expect(throws: SyncCloudStoreError.unknown) {
            try CloudKitPrivateSnapshotStore.validateZoneSaveResult(nil, zoneID: zoneID)
        }
        #expect(throws: SyncCloudStoreError.unknown) {
            try CloudKitPrivateSnapshotStore.validateZoneSaveResult(
                .failure(StorageResultError()),
                zoneID: zoneID
            )
        }
        #expect(throws: Never.self) {
            try CloudKitPrivateSnapshotStore.validateZoneDeleteResult(.success(()))
        }
        #expect(throws: SyncCloudStoreError.unknown) {
            try CloudKitPrivateSnapshotStore.validateZoneDeleteResult(nil)
        }
        #expect(throws: SyncCloudStoreError.unknown) {
            try CloudKitPrivateSnapshotStore.validateZoneDeleteResult(
                .failure(StorageResultError())
            )
        }
    }

    @Test("Persisted CloudKit change tokens have strict local size and decode bounds")
    func changeTokenValidation() throws {
        #expect(throws: SyncCloudStoreError.invalidChangeToken) {
            try SyncCloudChangeToken(encodedValue: Data())
        }
        #expect(throws: SyncCloudStoreError.invalidChangeToken) {
            try SyncCloudChangeToken(encodedValue: Data(
                repeating: 0,
                count: SyncCloudChangeToken.maximumEncodedBytes + 1
            ))
        }

        let malformed = try SyncCloudChangeToken(encodedValue: Data([1, 2, 3]))
        let encoded = try JSONEncoder().encode(malformed)
        #expect(try JSONDecoder().decode(SyncCloudChangeToken.self, from: encoded) == malformed)
        #expect(throws: SyncCloudStoreError.invalidChangeToken) {
            try malformed.serverToken()
        }
    }

    @Test("A stale CloudKit change tag is refetched exactly once")
    func conflictRetryPolicy() {
        #expect(CloudKitPrivateSnapshotStore.maximumConflictSaveAttempts == 2)
        #expect(CloudKitPrivateSnapshotStore.shouldRetrySave(.conflict, afterAttempt: 0))
        #expect(!CloudKitPrivateSnapshotStore.shouldRetrySave(.conflict, afterAttempt: 1))
        #expect(!CloudKitPrivateSnapshotStore.shouldRetrySave(.networkUnavailable, afterAttempt: 0))
    }

    @Test("The push subscription is a fixed-zone, content-free record-zone subscription")
    func fixedZoneSubscription() {
        let subscription = CloudKitSyncRecordCodec.zoneSubscription(subscriptionID: CloudKitPrivateSnapshotStore.subscriptionID)
        #expect(subscription.zoneID == CloudKitSyncRecordCodec.zoneID())
        #expect(subscription.subscriptionID == CloudKitPrivateSnapshotStore.subscriptionID)
        #expect(subscription.notificationInfo?.shouldSendContentAvailable == true)
        #expect(subscription.notificationInfo?.alertBody == nil)
        #expect(subscription.notificationInfo?.soundName == nil)
    }
}
