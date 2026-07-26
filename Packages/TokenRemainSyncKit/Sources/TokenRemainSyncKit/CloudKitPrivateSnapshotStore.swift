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
    case recordNotFound
    case zoneNotFound
    case malformedRecord(SyncCloudRecordValidationError)
    case unknown
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

/// Fixed, opaque record codec for the private CloudKit database. Keeping this
/// as pure record conversion lets the suite verify field allowlisting without
/// making a network or iCloud Keychain request.
public enum CloudKitSyncRecordCodec {
    public static let zoneName = "TokenRemainSync-v1"
    public static let recordType = "TRCurrentSnapshot"
    public static let currentRecordName = "current-v1"

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

    public static func record(for envelope: EncryptedSyncEnvelope) throws -> CKRecord {
        let encodedEnvelope = try envelope.encoded()
        let record = CKRecord(recordType: recordType, recordID: currentRecordID())
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
        guard record.recordID == currentRecordID() else {
            throw SyncCloudRecordValidationError.unexpectedRecordID
        }
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
        guard record.recordID.recordName == currentRecordName,
              record.recordID.zoneID.zoneName == zoneName,
              record.recordID.zoneID.ownerName == CKCurrentUserDefaultName else {
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
}

/// Transport boundary for a user's CloudKit private database. This store owns
/// one custom zone and one fixed record; it never queries arbitrary records or
/// stores a plaintext DTO.
public protocol SyncCloudSnapshotStoring: Sendable {
    func accountStatus() async throws -> SyncCloudAccountStatus
    func ensureZone() async throws
    func save(_ envelope: EncryptedSyncEnvelope) async throws
    func fetch() async throws -> SyncCloudStoredEnvelope?
    func deleteCurrent() async throws
    func deleteZone() async throws
    func ensureSubscription() async throws
}

public actor CloudKitPrivateSnapshotStore: SyncCloudSnapshotStoring {
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
            let zone = CKRecordZone(zoneID: CloudKitSyncRecordCodec.zoneID())
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        } catch {
            throw Self.map(error)
        }
    }

    public func save(_ envelope: EncryptedSyncEnvelope) async throws {
        try await ensureZone()
        for attempt in 0..<Self.maximumConflictSaveAttempts {
            do {
                try await saveOnce(envelope)
                return
            } catch let error as SyncCloudStoreError {
                guard Self.shouldRetrySave(error, afterAttempt: attempt) else {
                    throw error
                }
            }
        }
    }

    /// Refetches the fixed record for every attempt so a CloudKit
    /// `serverRecordChanged` response is retried with the newest change tag.
    private func saveOnce(_ envelope: EncryptedSyncEnvelope) async throws {
        var record: CKRecord
        do {
            record = try await database.record(for: CloudKitSyncRecordCodec.currentRecordID())
            try CloudKitSyncRecordCodec.overwrite(record, with: envelope)
        } catch let error as SyncCloudRecordValidationError {
            throw SyncCloudStoreError.malformedRecord(error)
        } catch let error as SyncCloudStoreError {
            throw error
        } catch {
            switch Self.map(error) {
            case .recordNotFound:
                do {
                    record = try CloudKitSyncRecordCodec.record(for: envelope)
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
        do {
            try await ensureZone()
            let record = try await database.record(for: CloudKitSyncRecordCodec.currentRecordID())
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
        do {
            _ = try await database.deleteRecord(withID: CloudKitSyncRecordCodec.currentRecordID())
        } catch {
            switch Self.map(error) {
            case .recordNotFound, .zoneNotFound:
                return
            case let mapped:
                throw mapped
            }
        }
    }

    public func deleteZone() async throws {
        do {
            _ = try await database.modifyRecordZones(saving: [], deleting: [CloudKitSyncRecordCodec.zoneID()])
        } catch {
            switch Self.map(error) {
            case .zoneNotFound:
                return
            case let mapped:
                throw mapped
            }
        }
    }

    /// Installs one custom-zone silent-push subscription. The receiving app
    /// treats the notification as a hint and always refetches/decrypts the fixed
    /// record, so notification payloads never contain quota data.
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
        case .requestRateLimited:
            return .requestRateLimited(retryAfterSeconds: retryAfterSeconds)
        case .serverRecordChanged, .batchRequestFailed:
            return .conflict
        case .unknownItem:
            return .recordNotFound
        case .zoneNotFound:
            return .zoneNotFound
        default:
            return .unknown
        }
    }
}

private let syncCloudStoreZeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
