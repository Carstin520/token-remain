@preconcurrency import CloudKit
import Foundation

/// The four account states the sync UI needs. CloudKit's richer error object is
/// deliberately not propagated so diagnostics cannot accidentally include a
/// record value or account-related user info.
public enum SyncCloudAccountStatus: Sendable, Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    init(_ status: CKAccountStatus) {
        switch status {
        case .available:
            self = .available
        case .noAccount:
            self = .noAccount
        case .restricted:
            self = .restricted
        case .couldNotDetermine:
            self = .couldNotDetermine
        case .temporarilyUnavailable:
            self = .temporarilyUnavailable
        @unknown default:
            self = .couldNotDetermine
        }
    }
}

/// Public, redacted failures for the CloudKit boundary. The raw CloudKit error
/// is intentionally discarded; callers can make retry/UI decisions without
/// logging encrypted data, record fields, or account details.
public enum SyncCloudStoreError: Error, Sendable, Equatable {
    case accountUnavailable
    case notAuthenticated
    case permissionDenied
    case networkUnavailable
    case serviceUnavailable
    case requestRateLimited(retryAfterSeconds: Double?)
    case conflict
    case changeTokenExpired
    case invalidChangeToken
    case recordNotFound
    case zoneNotFound
    case malformedRecord(SyncCloudRecordValidationError)
    case unknown
}

public enum SyncCloudRecordKind: Sendable, Equatable {
    case legacyCurrent
    case source(UUID)
}

public enum SyncCloudRecordValidationError: Error, Sendable, Equatable {
    case unexpectedRecordType
    case unexpectedRecordID
    case missingField(String)
    case invalidField(String)
    case metadataMismatch(String)
    case invalidEnvelope
}

/// Cleartext metadata permitted beside the opaque envelope. It intentionally
/// excludes provider names, quota values, account data, error text, tokens, and
/// paths. The fields are duplicated from the authenticated envelope only to
/// support CloudKit ordering and operational diagnostics.
public struct SyncCloudRecordMetadata: Sendable, Equatable {
    public let envelopeVersion: Int
    public let keyID: UUID
    public let sourceInstanceID: UUID
    public let sequence: UInt64
    public let generatedAt: Date
}

public struct SyncCloudStoredEnvelope: Sendable, Equatable {
    public let envelope: EncryptedSyncEnvelope
    public let metadata: SyncCloudRecordMetadata
    /// CloudKit's server-assigned record modification time. This is transport
    /// telemetry only and is never trusted for authentication or replay order.
    public let macUploadedAt: Date?

    public init(
        envelope: EncryptedSyncEnvelope,
        metadata: SyncCloudRecordMetadata,
        macUploadedAt: Date? = nil
    ) {
        self.envelope = envelope
        self.metadata = metadata
        self.macUploadedAt = macUploadedAt
    }
}

/// Opaque, locally persisted cursor for incremental custom-zone changes.
/// Clients must not inspect or derive ordering from its contents.
public struct SyncCloudChangeToken: Codable, Sendable, Equatable {
    public static let maximumEncodedBytes = 64 * 1_024

    public let encodedValue: Data

    public init(encodedValue: Data) throws {
        guard !encodedValue.isEmpty,
              encodedValue.count <= Self.maximumEncodedBytes else {
            throw SyncCloudStoreError.invalidChangeToken
        }
        self.encodedValue = encodedValue
    }

    init(serverToken: CKServerChangeToken) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: serverToken,
            requiringSecureCoding: true
        )
        try self.init(encodedValue: data)
    }

    func serverToken() throws -> CKServerChangeToken {
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: encodedValue
            ) else {
                throw SyncCloudStoreError.invalidChangeToken
            }
            return token
        } catch let error as SyncCloudStoreError {
            throw error
        } catch {
            throw SyncCloudStoreError.invalidChangeToken
        }
    }

    private enum CodingKeys: String, CodingKey {
        case encodedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .encodedValue)
        do {
            try self.init(encodedValue: data)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .encodedValue,
                in: container,
                debugDescription: "Invalid CloudKit change token"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(encodedValue, forKey: .encodedValue)
    }
}

public struct SyncCloudSourceChangeBatch: Sendable, Equatable {
    public let changedSources: [SyncCloudStoredEnvelope]
    public let deletedSourceInstanceIDs: [UUID]
    /// Record names skipped because their source-v2 identity or payload was
    /// malformed. The zone token still advances so one permanently bad record
    /// cannot poison every subsequent incremental fetch.
    public let rejectedRecordNames: [String]
    public let nextChangeToken: SyncCloudChangeToken

    public init(
        changedSources: [SyncCloudStoredEnvelope],
        deletedSourceInstanceIDs: [UUID],
        rejectedRecordNames: [String] = [],
        nextChangeToken: SyncCloudChangeToken
    ) {
        self.changedSources = changedSources
        self.deletedSourceInstanceIDs = deletedSourceInstanceIDs
        self.rejectedRecordNames = rejectedRecordNames
        self.nextChangeToken = nextChangeToken
    }
}

/// Fixed, opaque record codec for the private CloudKit database. Keeping this
/// as pure record conversion lets the suite verify field allowlisting without
/// making a network or iCloud Keychain request.
public enum CloudKitSyncRecordCodec {
    public static let zoneName = "TokenRemainSync-v1"
    public static let recordType = "TRCurrentSnapshot"
    public static let currentRecordName = "current-v1"
    public static let sourceRecordPrefix = "source-v2-"

    public static let encryptedEnvelopeField = "encryptedEnvelope"
    public static let envelopeVersionField = "envelopeVersion"
    public static let keyIDField = "keyID"
    public static let sourceInstanceIDField = "sourceInstanceID"
    public static let sequenceField = "sequence"
    public static let generatedAtField = "generatedAt"

    public static func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public static func currentRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: currentRecordName, zoneID: zoneID())
    }

    public static func sourceRecordName(for sourceInstanceID: UUID) -> String {
        sourceRecordPrefix + sourceInstanceID.uuidString.lowercased()
    }

    public static func sourceRecordID(for sourceInstanceID: UUID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: sourceRecordName(for: sourceInstanceID),
            zoneID: zoneID()
        )
    }

    /// Returns nil for future/unknown records in the app-owned zone so newer
    /// record families can coexist. A malformed `source-v2-` name fails closed.
    public static func recordKind(for recordID: CKRecord.ID) throws -> SyncCloudRecordKind? {
        guard recordID.zoneID.zoneName == zoneName,
              recordID.zoneID.ownerName == CKCurrentUserDefaultName else {
            throw SyncCloudRecordValidationError.unexpectedRecordID
        }
        if recordID.recordName == currentRecordName {
            return .legacyCurrent
        }
        guard recordID.recordName.hasPrefix(sourceRecordPrefix) else {
            return nil
        }
        let suffix = String(recordID.recordName.dropFirst(sourceRecordPrefix.count))
        guard let sourceInstanceID = UUID(uuidString: suffix),
              sourceInstanceID != syncCloudStoreZeroUUID,
              recordID.recordName == sourceRecordName(for: sourceInstanceID) else {
            throw SyncCloudRecordValidationError.unexpectedRecordID
        }
        return .source(sourceInstanceID)
    }

    public static func record(for envelope: EncryptedSyncEnvelope) throws -> CKRecord {
        try record(for: envelope, recordID: currentRecordID())
    }

    public static func sourceRecord(for envelope: EncryptedSyncEnvelope) throws -> CKRecord {
        try record(
            for: envelope,
            recordID: sourceRecordID(for: envelope.sourceInstanceID)
        )
    }

    private static func record(
        for envelope: EncryptedSyncEnvelope,
        recordID: CKRecord.ID
    ) throws -> CKRecord {
        let encodedEnvelope = try envelope.encoded()
        let record = CKRecord(recordType: recordType, recordID: recordID)
        try validate(recordID: recordID, for: envelope)
        applyAllowlistedFields(to: record, encodedEnvelope: encodedEnvelope, envelope: envelope)
        return record
    }

    /// Reuses a record obtained from CloudKit so its server change tag is kept.
    /// This is the required upsert path: a fresh `CKRecord` with an existing ID
    /// would otherwise conflict under CloudKit's default save policy. Existing
    /// fields are cleared first, so no historical or unexpected plaintext field
    /// survives a subsequent sync write.
    public static func overwrite(_ record: CKRecord, with envelope: EncryptedSyncEnvelope) throws {
        guard record.recordType == recordType else {
            throw SyncCloudRecordValidationError.unexpectedRecordType
        }
        try validate(recordID: record.recordID, for: envelope)
        let encodedEnvelope = try envelope.encoded()
        let encryptedKeys = Set(record.encryptedValues.allKeys())
        for key in record.allKeys() where !encryptedKeys.contains(key) {
            record[key] = nil
        }
        for key in encryptedKeys {
            record.encryptedValues[key] = nil
        }
        applyAllowlistedFields(to: record, encodedEnvelope: encodedEnvelope, envelope: envelope)
    }

    /// Creates a content-free, custom-zone subscription. Notifications are only
    /// a refresh hint; the receiver must fetch and authenticate the record.
    public static func zoneSubscription(subscriptionID: String) -> CKRecordZoneSubscription {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID(), subscriptionID: subscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        return subscription
    }

    private static func applyAllowlistedFields(
        to record: CKRecord,
        encodedEnvelope: Data,
        envelope: EncryptedSyncEnvelope
    ) {
        // CloudKit field encryption wraps the already AES-GCM-encrypted app
        // envelope. The application layer remains the trust boundary; this is
        // defense in depth and keeps the payload out of ordinary record fields.
        record.encryptedValues[encryptedEnvelopeField] = encodedEnvelope as NSData
        record[envelopeVersionField] = NSNumber(value: envelope.envelopeVersion)
        record[keyIDField] = envelope.keyID.uuidString.lowercased() as NSString
        record[sourceInstanceIDField] = envelope.sourceInstanceID.uuidString.lowercased() as NSString
        // UInt64 is represented as decimal text so values above Int64.max keep
        // their exact replay-ordering semantics in CloudKit metadata.
        record[sequenceField] = String(envelope.sequence) as NSString
        record[generatedAtField] = envelope.generatedAt as NSDate
    }

    public static func storedEnvelope(from record: CKRecord) throws -> SyncCloudStoredEnvelope {
        guard record.recordType == recordType else {
            throw SyncCloudRecordValidationError.unexpectedRecordType
        }
        guard let kind = try recordKind(for: record.recordID) else {
            throw SyncCloudRecordValidationError.unexpectedRecordID
        }

        let data = try requiredEncryptedData(record, field: encryptedEnvelopeField)
        let envelope: EncryptedSyncEnvelope
        do {
            envelope = try EncryptedSyncEnvelope.decoded(from: data)
        } catch {
            throw SyncCloudRecordValidationError.invalidEnvelope
        }

        let metadata = try decodeMetadata(from: record)
        guard metadata.envelopeVersion == envelope.envelopeVersion else {
            throw SyncCloudRecordValidationError.metadataMismatch(envelopeVersionField)
        }
        guard metadata.keyID == envelope.keyID else {
            throw SyncCloudRecordValidationError.metadataMismatch(keyIDField)
        }
        guard metadata.sourceInstanceID == envelope.sourceInstanceID else {
            throw SyncCloudRecordValidationError.metadataMismatch(sourceInstanceIDField)
        }
        if case .source(let recordSourceInstanceID) = kind,
           recordSourceInstanceID != envelope.sourceInstanceID {
            throw SyncCloudRecordValidationError.metadataMismatch(sourceInstanceIDField)
        }
        guard metadata.sequence == envelope.sequence else {
            throw SyncCloudRecordValidationError.metadataMismatch(sequenceField)
        }
        guard try sameMillisecond(metadata.generatedAt, envelope.generatedAt) else {
            throw SyncCloudRecordValidationError.metadataMismatch(generatedAtField)
        }
        let macUploadedAt = record.modificationDate.flatMap { date in
            date.timeIntervalSince1970.isFinite ? date : nil
        }
        return SyncCloudStoredEnvelope(
            envelope: envelope,
            metadata: metadata,
            macUploadedAt: macUploadedAt
        )
    }

    private static func decodeMetadata(from record: CKRecord) throws -> SyncCloudRecordMetadata {
        let version = try requiredNumber(record, field: envelopeVersionField)
        guard version.intValue >= 0,
              version.doubleValue == Double(version.intValue) else {
            throw SyncCloudRecordValidationError.invalidField(envelopeVersionField)
        }
        let keyID = try requiredUUID(record, field: keyIDField)
        let sourceInstanceID = try requiredUUID(record, field: sourceInstanceIDField)
        let sequenceString = try requiredString(record, field: sequenceField)
        guard let sequence = UInt64(sequenceString), sequence > 0 else {
            throw SyncCloudRecordValidationError.invalidField(sequenceField)
        }
        let generatedAt = try requiredDate(record, field: generatedAtField)
        guard generatedAt.timeIntervalSince1970.isFinite else {
            throw SyncCloudRecordValidationError.invalidField(generatedAtField)
        }
        return SyncCloudRecordMetadata(
            envelopeVersion: version.intValue,
            keyID: keyID,
            sourceInstanceID: sourceInstanceID,
            sequence: sequence,
            generatedAt: generatedAt
        )
    }

    private static func requiredEncryptedData(_ record: CKRecord, field: String) throws -> Data {
        guard let value = record.encryptedValues[field] else {
            throw SyncCloudRecordValidationError.missingField(field)
        }
        guard let data = value as? Data else {
            throw SyncCloudRecordValidationError.invalidField(field)
        }
        guard !data.isEmpty, data.count <= EncryptedSyncEnvelope.maximumEncodedEnvelopeBytes else {
            throw SyncCloudRecordValidationError.invalidField(field)
        }
        return data
    }

    private static func requiredNumber(_ record: CKRecord, field: String) throws -> NSNumber {
        guard let value = record[field] else {
            throw SyncCloudRecordValidationError.missingField(field)
        }
        guard let number = value as? NSNumber else {
            throw SyncCloudRecordValidationError.invalidField(field)
        }
        return number
    }

    private static func requiredString(_ record: CKRecord, field: String) throws -> String {
        guard let value = record[field] else {
            throw SyncCloudRecordValidationError.missingField(field)
        }
        guard let string = value as? String, !string.isEmpty else {
            throw SyncCloudRecordValidationError.invalidField(field)
        }
        return string
    }

    private static func requiredUUID(_ record: CKRecord, field: String) throws -> UUID {
        let string = try requiredString(record, field: field)
        guard let value = UUID(uuidString: string), value != syncCloudStoreZeroUUID else {
            throw SyncCloudRecordValidationError.invalidField(field)
        }
        return value
    }

    private static func requiredDate(_ record: CKRecord, field: String) throws -> Date {
        guard let value = record[field] else {
            throw SyncCloudRecordValidationError.missingField(field)
        }
        guard let date = value as? Date else {
            throw SyncCloudRecordValidationError.invalidField(field)
        }
        return date
    }

    private static func sameMillisecond(_ lhs: Date, _ rhs: Date) throws -> Bool {
        try SyncTimestamp.milliseconds(lhs, field: .generatedAt) ==
            SyncTimestamp.milliseconds(rhs, field: .generatedAt)
    }

    private static func validate(
        recordID: CKRecord.ID,
        for envelope: EncryptedSyncEnvelope
    ) throws {
        guard let kind = try recordKind(for: recordID) else {
            throw SyncCloudRecordValidationError.unexpectedRecordID
        }
        if case .source(let sourceInstanceID) = kind,
           sourceInstanceID != envelope.sourceInstanceID {
            throw SyncCloudRecordValidationError.metadataMismatch(sourceInstanceIDField)
        }
    }
}

enum SyncCloudSourceUpsertDecision: Sendable, Equatable {
    case create
    case overwrite
    case duplicate
    case rejectConflict
}

enum SyncCloudSourceUpsertPolicy {
    static func decision(
        existing: EncryptedSyncEnvelope?,
        candidate: EncryptedSyncEnvelope
    ) -> SyncCloudSourceUpsertDecision {
        guard let existing else { return .create }
        guard existing.sourceInstanceID == candidate.sourceInstanceID else {
            return .rejectConflict
        }
        if candidate.sequence > existing.sequence { return .overwrite }
        if candidate.sequence < existing.sequence { return .rejectConflict }
        return candidate == existing ? .duplicate : .rejectConflict
    }
}

/// Legacy transport boundary retained while v1.1 clients still read the fixed
/// `current-v1` compatibility record.
public protocol SyncCloudSnapshotStoring: Sendable {
    func accountStatus() async throws -> SyncCloudAccountStatus
    func ensureZone() async throws
    func save(_ envelope: EncryptedSyncEnvelope) async throws
    func fetch() async throws -> SyncCloudStoredEnvelope?
    func deleteCurrent() async throws
    func deleteZone() async throws
    func ensureSubscription() async throws
}

/// v1.2 per-Mac transport. Source records share the existing record type and
/// encrypted field allowlist, but use one deterministic record ID per source.
public protocol SyncCloudSourceStoring: SyncCloudSnapshotStoring {
    func saveSource(_ envelope: EncryptedSyncEnvelope) async throws
    func fetchSource(sourceInstanceID: UUID) async throws -> SyncCloudStoredEnvelope?
    func deleteSource(sourceInstanceID: UUID) async throws
    func fetchSourceChanges(
        since changeToken: SyncCloudChangeToken?
    ) async throws -> SyncCloudSourceChangeBatch
}

public actor CloudKitPrivateSnapshotStore: SyncCloudSourceStoring {
    public static let subscriptionID = "TokenRemainSync-current-v1"
    public static let maximumConflictSaveAttempts = 2

    private let container: CKContainer
    private let database: CKDatabase

    public init(containerIdentifier: String) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
    }

    public init(container: CKContainer) {
        self.container = container
        self.database = container.privateCloudDatabase
    }

    public func accountStatus() async throws -> SyncCloudAccountStatus {
        do {
            return SyncCloudAccountStatus(try await container.accountStatus())
        } catch {
            throw Self.map(error)
        }
    }

    public func ensureZone() async throws {
        do {
            let zoneID = CloudKitSyncRecordCodec.zoneID()
            let zone = CKRecordZone(zoneID: zoneID)
            let results = try await database.modifyRecordZones(
                saving: [zone],
                deleting: []
            )
            try Self.validateZoneSaveResult(results.saveResults[zoneID], zoneID: zoneID)
        } catch let mapped as SyncCloudStoreError {
            throw mapped
        } catch {
            throw Self.map(error)
        }
    }

    public func save(_ envelope: EncryptedSyncEnvelope) async throws {
        try await save(
            envelope,
            recordID: CloudKitSyncRecordCodec.currentRecordID(),
            enforcesSourceSequence: false
        )
    }

    public func saveSource(_ envelope: EncryptedSyncEnvelope) async throws {
        try await save(
            envelope,
            recordID: CloudKitSyncRecordCodec.sourceRecordID(
                for: envelope.sourceInstanceID
            ),
            enforcesSourceSequence: true
        )
    }

    private func save(
        _ envelope: EncryptedSyncEnvelope,
        recordID: CKRecord.ID,
        enforcesSourceSequence: Bool
    ) async throws {
        try await ensureZone()
        for attempt in 0..<Self.maximumConflictSaveAttempts {
            do {
                try await saveOnce(
                    envelope,
                    recordID: recordID,
                    enforcesSourceSequence: enforcesSourceSequence
                )
                return
            } catch let error as SyncCloudStoreError {
                guard Self.shouldRetrySave(error, afterAttempt: attempt) else {
                    throw error
                }
            }
        }
    }

    /// Refetches the target record for every attempt so a CloudKit
    /// `serverRecordChanged` response is retried with the newest change tag.
    private func saveOnce(
        _ envelope: EncryptedSyncEnvelope,
        recordID: CKRecord.ID,
        enforcesSourceSequence: Bool
    ) async throws {
        var record: CKRecord
        do {
            record = try await database.record(for: recordID)
            if enforcesSourceSequence {
                let stored = try CloudKitSyncRecordCodec.storedEnvelope(from: record)
                switch SyncCloudSourceUpsertPolicy.decision(
                    existing: stored.envelope,
                    candidate: envelope
                ) {
                case .duplicate:
                    return
                case .overwrite:
                    break
                case .create, .rejectConflict:
                    throw SyncCloudStoreError.conflict
                }
            }
            try CloudKitSyncRecordCodec.overwrite(record, with: envelope)
        } catch let error as SyncCloudRecordValidationError {
            throw SyncCloudStoreError.malformedRecord(error)
        } catch let error as SyncCloudStoreError {
            throw error
        } catch {
            switch Self.map(error) {
            case .recordNotFound:
                do {
                    record = enforcesSourceSequence
                        ? try CloudKitSyncRecordCodec.sourceRecord(for: envelope)
                        : try CloudKitSyncRecordCodec.record(for: envelope)
                } catch {
                    throw SyncCloudStoreError.malformedRecord(.invalidEnvelope)
                }
            case let mapped:
                throw mapped
            }
        }
        do {
            _ = try await database.save(record)
        } catch {
            throw Self.map(error)
        }
    }

    static func shouldRetrySave(_ error: SyncCloudStoreError, afterAttempt attempt: Int) -> Bool {
        error == .conflict && attempt + 1 < maximumConflictSaveAttempts
    }

    public func fetch() async throws -> SyncCloudStoredEnvelope? {
        try await fetch(recordID: CloudKitSyncRecordCodec.currentRecordID())
    }

    public func fetchSource(
        sourceInstanceID: UUID
    ) async throws -> SyncCloudStoredEnvelope? {
        try await fetch(
            recordID: CloudKitSyncRecordCodec.sourceRecordID(for: sourceInstanceID)
        )
    }

    private func fetch(recordID: CKRecord.ID) async throws -> SyncCloudStoredEnvelope? {
        do {
            try await ensureZone()
            let record = try await database.record(for: recordID)
            do {
                return try CloudKitSyncRecordCodec.storedEnvelope(from: record)
            } catch let validationError as SyncCloudRecordValidationError {
                throw SyncCloudStoreError.malformedRecord(validationError)
            }
        } catch let error as SyncCloudStoreError {
            throw error
        } catch {
            switch Self.map(error) {
            case .recordNotFound, .zoneNotFound:
                return nil
            case let mapped:
                throw mapped
            }
        }
    }

    public func deleteCurrent() async throws {
        try await delete(recordID: CloudKitSyncRecordCodec.currentRecordID())
    }

    public func deleteSource(sourceInstanceID: UUID) async throws {
        try await delete(
            recordID: CloudKitSyncRecordCodec.sourceRecordID(for: sourceInstanceID)
        )
    }

    private func delete(recordID: CKRecord.ID) async throws {
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch {
            switch Self.map(error) {
            case .recordNotFound, .zoneNotFound:
                return
            case let mapped:
                throw mapped
            }
        }
    }

    public func fetchSourceChanges(
        since changeToken: SyncCloudChangeToken?
    ) async throws -> SyncCloudSourceChangeBatch {
        try await ensureZone()
        let previousServerChangeToken = try changeToken?.serverToken()
        let zoneID = CloudKitSyncRecordCodec.zoneID()
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: previousServerChangeToken,
            desiredKeys: [
                CloudKitSyncRecordCodec.encryptedEnvelopeField,
                CloudKitSyncRecordCodec.envelopeVersionField,
                CloudKitSyncRecordCodec.keyIDField,
                CloudKitSyncRecordCodec.sourceInstanceIDField,
                CloudKitSyncRecordCodec.sequenceField,
                CloudKitSyncRecordCodec.generatedAtField,
            ]
        )
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: configuration]
        )
        operation.fetchAllChanges = true
        operation.qualityOfService = .utility
        let accumulator = SyncCloudZoneChangeAccumulator()

        return try await withCheckedThrowingContinuation { continuation in
            operation.recordWasChangedBlock = { recordID, result in
                do {
                    guard let kind = try CloudKitSyncRecordCodec.recordKind(for: recordID),
                          case .source = kind else {
                        return
                    }
                    let record = try result.get()
                    guard record.recordID == recordID else {
                        throw SyncCloudRecordValidationError.unexpectedRecordID
                    }
                    let stored = try CloudKitSyncRecordCodec.storedEnvelope(from: record)
                    accumulator.recordChange(stored)
                } catch is SyncCloudRecordValidationError {
                    accumulator.recordRejection(recordID.recordName)
                } catch {
                    accumulator.recordFailure(Self.map(error))
                }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                do {
                    guard let kind = try CloudKitSyncRecordCodec.recordKind(for: recordID),
                          case .source(let sourceInstanceID) = kind else {
                        return
                    }
                    accumulator.recordDeletion(sourceInstanceID)
                } catch is SyncCloudRecordValidationError {
                    accumulator.recordRejection(recordID.recordName)
                } catch {
                    accumulator.recordFailure(Self.map(error))
                }
            }
            operation.recordZoneFetchResultBlock = { fetchedZoneID, result in
                guard fetchedZoneID == zoneID else {
                    accumulator.recordFailure(.zoneNotFound)
                    return
                }
                switch result {
                case .success(let response):
                    accumulator.recordServerToken(response.serverChangeToken)
                case .failure(let error):
                    accumulator.recordFailure(Self.map(error))
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                if case .failure(let error) = result {
                    accumulator.recordFailure(Self.map(error))
                }
                do {
                    continuation.resume(returning: try accumulator.finalBatch())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    public func deleteZone() async throws {
        do {
            let zoneID = CloudKitSyncRecordCodec.zoneID()
            let results = try await database.modifyRecordZones(
                saving: [],
                deleting: [zoneID]
            )
            try Self.validateZoneDeleteResult(results.deleteResults[zoneID])
        } catch let mapped as SyncCloudStoreError {
            switch mapped {
            case .zoneNotFound, .recordNotFound:
                return
            case let other:
                throw other
            }
        } catch {
            switch Self.map(error) {
            case .zoneNotFound, .recordNotFound:
                return
            case let mapped:
                throw mapped
            }
        }
    }

    /// Installs one custom-zone silent-push subscription. Receivers treat the
    /// notification as a hint and refetch authenticated zone records (legacy
    /// clients still refetch current-v1), so payloads never contain quota data.
    public func ensureSubscription() async throws {
        try await ensureZone()
        do {
            let existing = try await database.subscription(for: Self.subscriptionID)
            if let zoneSubscription = existing as? CKRecordZoneSubscription,
               zoneSubscription.zoneID == CloudKitSyncRecordCodec.zoneID() {
                return
            }
            // An older app version may have used this ID for a broader
            // subscription. Replace it rather than retaining a subscription
            // outside the fixed private zone.
            _ = try await database.deleteSubscription(withID: Self.subscriptionID)
        } catch {
            guard case .recordNotFound = Self.map(error) else {
                throw Self.map(error)
            }
        }

        let subscription = CloudKitSyncRecordCodec.zoneSubscription(subscriptionID: Self.subscriptionID)
        do {
            _ = try await database.save(subscription)
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: Error) -> SyncCloudStoreError {
        guard let cloudError = error as? CKError else {
            return .unknown
        }
        let retryAfter = (cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        return map(code: cloudError.code, retryAfterSeconds: retryAfter)
    }

    static func map(code: CKError.Code, retryAfterSeconds: Double? = nil) -> SyncCloudStoreError {
        switch code {
        case .notAuthenticated:
            return .notAuthenticated
        case .permissionFailure:
            return .permissionDenied
        case .networkUnavailable, .networkFailure:
            return .networkUnavailable
        case .serviceUnavailable:
            return .serviceUnavailable
        case .accountTemporarilyUnavailable, .serverResponseLost:
            return .serviceUnavailable
        case .requestRateLimited, .zoneBusy, .limitExceeded:
            return .requestRateLimited(retryAfterSeconds: retryAfterSeconds)
        case .serverRecordChanged, .batchRequestFailed:
            return .conflict
        case .changeTokenExpired:
            return .changeTokenExpired
        case .unknownItem:
            return .recordNotFound
        case .zoneNotFound:
            return .zoneNotFound
        case .userDeletedZone:
            return .zoneNotFound
        default:
            return .unknown
        }
    }

    static func validateZoneSaveResult(
        _ result: Result<CKRecordZone, any Error>?,
        zoneID: CKRecordZone.ID
    ) throws {
        guard let result else { throw SyncCloudStoreError.unknown }
        do {
            let savedZone = try result.get()
            guard savedZone.zoneID == zoneID else {
                throw SyncCloudStoreError.unknown
            }
        } catch let mapped as SyncCloudStoreError {
            throw mapped
        } catch {
            throw map(error)
        }
    }

    static func validateZoneDeleteResult(
        _ result: Result<Void, any Error>?
    ) throws {
        guard let result else { throw SyncCloudStoreError.unknown }
        do {
            try result.get()
        } catch {
            throw map(error)
        }
    }
}

struct SyncCloudSourceChangeReducer: Sendable {
    private var changes: [UUID: SyncCloudStoredEnvelope] = [:]
    private var deletions: Set<UUID> = []
    private var rejections: Set<String> = []

    mutating func recordChange(_ stored: SyncCloudStoredEnvelope) {
        let sourceInstanceID = stored.envelope.sourceInstanceID
        if let existing = changes[sourceInstanceID] {
            switch SyncCloudSourceUpsertPolicy.decision(
                existing: existing.envelope,
                candidate: stored.envelope
            ) {
            case .overwrite:
                changes[sourceInstanceID] = stored
            case .duplicate:
                break
            case .create, .rejectConflict:
                recordRejection(
                    CloudKitSyncRecordCodec.sourceRecordName(for: sourceInstanceID)
                )
            }
        } else {
            changes[sourceInstanceID] = stored
        }
        deletions.remove(sourceInstanceID)
    }

    mutating func recordDeletion(_ sourceInstanceID: UUID) {
        changes.removeValue(forKey: sourceInstanceID)
        deletions.insert(sourceInstanceID)
    }

    mutating func recordRejection(_ recordName: String) {
        rejections.insert(recordName)
    }

    var changedSources: [SyncCloudStoredEnvelope] {
        changes.values.sorted {
            $0.envelope.sourceInstanceID.uuidString <
                $1.envelope.sourceInstanceID.uuidString
        }
    }

    var deletedSourceInstanceIDs: [UUID] {
        deletions.sorted { $0.uuidString < $1.uuidString }
    }

    var rejectedRecordNames: [String] {
        rejections.sorted()
    }
}

private final class SyncCloudZoneChangeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var reducer = SyncCloudSourceChangeReducer()
    private var serverToken: CKServerChangeToken?
    private var failure: SyncCloudStoreError?

    func recordChange(_ stored: SyncCloudStoredEnvelope) {
        lock.lock()
        defer { lock.unlock() }
        reducer.recordChange(stored)
    }

    func recordDeletion(_ sourceInstanceID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        reducer.recordDeletion(sourceInstanceID)
    }

    func recordRejection(_ recordName: String) {
        lock.lock()
        defer { lock.unlock() }
        reducer.recordRejection(recordName)
    }

    func recordServerToken(_ token: CKServerChangeToken) {
        lock.lock()
        defer { lock.unlock() }
        serverToken = token
    }

    func recordFailure(_ error: SyncCloudStoreError) {
        lock.lock()
        defer { lock.unlock() }
        failure = failure ?? error
    }

    func finalBatch() throws -> SyncCloudSourceChangeBatch {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        guard let serverToken else { throw SyncCloudStoreError.invalidChangeToken }
        let token = try SyncCloudChangeToken(serverToken: serverToken)
        return SyncCloudSourceChangeBatch(
            changedSources: reducer.changedSources,
            deletedSourceInstanceIDs: reducer.deletedSourceInstanceIDs,
            rejectedRecordNames: reducer.rejectedRecordNames,
            nextChangeToken: token
        )
    }
}

private let syncCloudStoreZeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
