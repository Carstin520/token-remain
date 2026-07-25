import CryptoKit
import Foundation

/// A 256-bit key used exclusively for cross-device snapshot encryption. Provider
/// credentials must never be wrapped in this type or placed in a synchronizable
/// Keychain item.
public struct SyncEncryptionKey: Sendable, Equatable {
    public static let byteCount = 32

    private let bytes: Data

    public init(rawValue: Data) throws {
        guard rawValue.count == Self.byteCount else {
            throw SyncProtocolError.invalidKeyLength(rawValue.count)
        }
        self.bytes = rawValue
    }

    public static func random() -> SyncEncryptionKey {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        // `SymmetricKey(size: .bits256)` is guaranteed to produce exactly 32 bytes.
        return try! SyncEncryptionKey(rawValue: bytes)
    }

    /// Exposed only for a dedicated synchronizable Keychain store. Callers must
    /// never log, serialize, or send this value to CloudKit.
    public var rawValue: Data { bytes }

    var cryptoKey: SymmetricKey { SymmetricKey(data: bytes) }
}

/// Application-layer AES-GCM envelope. The CloudKit record carries this opaque
/// value and may expose only its version/key ID/timestamps as non-sensitive
/// metadata. Provider IDs and quota values are always inside `sealedPayload`.
public struct EncryptedSyncEnvelope: Codable, Sendable, Equatable {
    public static let currentEnvelopeVersion = 1
    public static let maximumPlaintextBytes = 20 * 1_024
    public static let maximumSealedPayloadBytes = maximumPlaintextBytes + 28
    public static let maximumEncodedEnvelopeBytes = 32 * 1_024

    public let envelopeVersion: Int
    public let keyID: UUID
    public let sourceInstanceID: UUID
    public let sequence: UInt64
    public let generatedAt: Date
    public let sealedPayload: Data

    public init(
        envelopeVersion: Int = EncryptedSyncEnvelope.currentEnvelopeVersion,
        keyID: UUID,
        sourceInstanceID: UUID,
        sequence: UInt64,
        generatedAt: Date,
        sealedPayload: Data
    ) throws {
        self.envelopeVersion = envelopeVersion
        self.keyID = keyID
        self.sourceInstanceID = sourceInstanceID
        self.sequence = sequence
        self.generatedAt = generatedAt
        self.sealedPayload = sealedPayload
        try validateHeaderAndSize()
    }

    public static func seal(
        _ snapshot: MobileUsageSnapshot,
        using key: SyncEncryptionKey,
        keyID: UUID,
        containerID: String,
        configuration: SyncValidationConfiguration = .current()
    ) throws -> EncryptedSyncEnvelope {
        let normalizedSnapshot = try snapshot.validatedForTransport(configuration: configuration).normalizedForWire()
        let payload = try normalizedSnapshot.encodedPayload()
        guard payload.count <= maximumPlaintextBytes else {
            throw SyncProtocolError.payloadTooLarge(payload.count)
        }

        let aad = try SyncCanonicalAAD.make(
            envelopeVersion: currentEnvelopeVersion,
            keyID: keyID,
            sourceInstanceID: normalizedSnapshot.sourceInstanceID,
            sequence: normalizedSnapshot.sequence,
            generatedAt: normalizedSnapshot.generatedAt,
            containerID: containerID
        )
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(payload, using: key.cryptoKey, authenticating: aad)
        } catch {
            throw SyncProtocolError.encryptionFailed
        }
        guard let combined = sealedBox.combined else {
            throw SyncProtocolError.encryptionFailed
        }
        return try EncryptedSyncEnvelope(
            keyID: keyID,
            sourceInstanceID: normalizedSnapshot.sourceInstanceID,
            sequence: normalizedSnapshot.sequence,
            generatedAt: normalizedSnapshot.generatedAt,
            sealedPayload: combined
        )
    }

    public func open(
        using key: SyncEncryptionKey,
        containerID: String,
        supportedProviderIDs: Set<String> = SyncedProviderID.supportedOnCurrentMobile,
        configuration: SyncValidationConfiguration = .current()
    ) throws -> MobileUsageSnapshot {
        try validateHeaderAndSize()
        let aad = try SyncCanonicalAAD.make(
            envelopeVersion: envelopeVersion,
            keyID: keyID,
            sourceInstanceID: sourceInstanceID,
            sequence: sequence,
            generatedAt: generatedAt,
            containerID: containerID
        )

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: sealedPayload)
        } catch {
            throw SyncProtocolError.malformedEnvelope
        }

        let payload: Data
        do {
            payload = try AES.GCM.open(box, using: key.cryptoKey, authenticating: aad)
        } catch {
            throw SyncProtocolError.authenticationFailed
        }
        guard payload.count <= Self.maximumPlaintextBytes else {
            throw SyncProtocolError.payloadTooLarge(payload.count)
        }

        let decoded: MobileUsageSnapshot
        do {
            decoded = try MobileUsageSnapshot.decodedPayload(from: payload)
        } catch {
            throw SyncProtocolError.malformedPayload
        }
        guard decoded.sourceInstanceID == sourceInstanceID,
              decoded.sequence == sequence,
              decoded.generatedAt == generatedAt else {
            throw SyncProtocolError.headerPayloadMismatch
        }
        do {
            return try decoded.validatedForConsumption(
                supportedProviderIDs: supportedProviderIDs,
                configuration: configuration
            )
        } catch let error as SyncValidationError {
            throw SyncProtocolError.validation(error)
        }
    }

    public func encoded() throws -> Data {
        let data = try SyncPayloadCodec.encode(self)
        guard data.count <= Self.maximumEncodedEnvelopeBytes else {
            throw SyncProtocolError.envelopeTooLarge(data.count)
        }
        return data
    }

    public static func decoded(from data: Data) throws -> EncryptedSyncEnvelope {
        guard data.count <= Self.maximumEncodedEnvelopeBytes else {
            throw SyncProtocolError.envelopeTooLarge(data.count)
        }
        let envelope: EncryptedSyncEnvelope
        do {
            envelope = try SyncPayloadCodec.decode(EncryptedSyncEnvelope.self, from: data)
        } catch let error as SyncProtocolError {
            throw error
        } catch {
            throw SyncProtocolError.malformedEnvelope
        }
        try envelope.validateHeaderAndSize()
        return envelope
    }

    private func validateHeaderAndSize() throws {
        guard envelopeVersion == Self.currentEnvelopeVersion else {
            throw SyncProtocolError.unsupportedEnvelopeVersion(envelopeVersion)
        }
        guard keyID != .syncProtocolZero else {
            throw SyncProtocolError.emptyKeyID
        }
        guard sourceInstanceID != .syncProtocolZero else {
            throw SyncProtocolError.emptySourceInstanceID
        }
        guard sequence > 0 else {
            throw SyncProtocolError.invalidSequence
        }
        guard generatedAt.timeIntervalSince1970.isFinite else {
            throw SyncProtocolError.invalidEnvelopeDate
        }
        guard !sealedPayload.isEmpty, sealedPayload.count <= Self.maximumSealedPayloadBytes else {
            throw SyncProtocolError.sealedPayloadTooLarge(sealedPayload.count)
        }
    }
}

public enum SyncProtocolError: Error, Sendable, Equatable {
    case invalidKeyLength(Int)
    case invalidContainerID
    case payloadTooLarge(Int)
    case envelopeTooLarge(Int)
    case sealedPayloadTooLarge(Int)
    case unsupportedEnvelopeVersion(Int)
    case emptyKeyID
    case emptySourceInstanceID
    case invalidSequence
    case invalidEnvelopeDate
    case malformedEnvelope
    case malformedPayload
    case encryptionFailed
    case authenticationFailed
    case headerPayloadMismatch
    case validation(SyncValidationError)
}

/// Canonical associated data binds the clear envelope header to the ciphertext.
/// Every value has a four-byte big-endian length prefix in a fixed order. This
/// avoids collisions that string interpolation or delimiter concatenation permit.
enum SyncCanonicalAAD {
    static func make(
        envelopeVersion: Int,
        keyID: UUID,
        sourceInstanceID: UUID,
        sequence: UInt64,
        generatedAt: Date,
        containerID: String
    ) throws -> Data {
        let containerBytes = Data(containerID.utf8)
        guard !containerBytes.isEmpty, containerBytes.count <= 255 else {
            throw SyncProtocolError.invalidContainerID
        }
        guard generatedAt.timeIntervalSince1970.isFinite else {
            throw SyncProtocolError.invalidEnvelopeDate
        }

        var result = Data("TRSYNC-AAD-1".utf8)
        appendLengthPrefixed(unsigned32(envelopeVersion), to: &result)
        appendLengthPrefixed(uuidBytes(keyID), to: &result)
        appendLengthPrefixed(uuidBytes(sourceInstanceID), to: &result)
        appendLengthPrefixed(unsigned64(sequence), to: &result)
        appendLengthPrefixed(try signed64(SyncTimestamp.milliseconds(generatedAt, field: .generatedAt)), to: &result)
        appendLengthPrefixed(containerBytes, to: &result)
        return result
    }

    private static func appendLengthPrefixed(_ value: Data, to result: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(value)
    }

    private static func unsigned32(_ value: Int) -> Data {
        var encoded = UInt32(clamping: value).bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private static func unsigned64(_ value: UInt64) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private static func signed64(_ value: Int64) throws -> Data {
        var encoded = UInt64(bitPattern: value).bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        var uuid = value.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}

private extension UUID {
    static let syncProtocolZero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
