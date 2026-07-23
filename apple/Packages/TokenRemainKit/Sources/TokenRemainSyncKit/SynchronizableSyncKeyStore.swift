@preconcurrency import Security
import Foundation

/// The encryption key and its public identifier. This value is intentionally
/// separate from provider credentials: the only supported persistence location
/// is ``SynchronizableSyncKeyStore``'s dedicated synchronizable Keychain
/// service.
public struct SyncKeyRecord: Sendable, Equatable {
    public let keyID: UUID
    public let key: SyncEncryptionKey

    public init(keyID: UUID, key: SyncEncryptionKey) throws {
        guard keyID != syncKeyStoreZeroUUID else {
            throw SyncKeyStoreError.invalidKeyID
        }
        self.keyID = keyID
        self.key = key
    }

    public init(keyID: UUID, rawKey: Data) throws {
        do {
            try self.init(keyID: keyID, key: SyncEncryptionKey(rawValue: rawKey))
        } catch SyncProtocolError.invalidKeyLength {
            throw SyncKeyStoreError.invalidKeyMaterial(rawKey.count)
        }
    }
}

/// Errors deliberately contain neither Keychain values nor provider secrets.
/// The status code is retained only for operational diagnostics where the
/// numeric Keychain result is safe to report.
public enum SyncKeyStoreError: Error, Sendable, Equatable {
    case invalidKeyID
    case invalidKeyMaterial(Int)
    case malformedCurrentPointer
    case currentKeyMissing(UUID)
    case duplicateItem
    case itemNotFound
    case missingEntitlement
    case interactionNotAllowed
    case keychainUnavailable
    case keychainFailure(Int32)
}

/// Small async boundary around Keychain. Production code uses
/// ``SecuritySynchronizableKeychainClient``; tests can use an in-memory client
/// without touching the user's iCloud Keychain.
public protocol SynchronizableKeychainClient: Sendable {
    func read(account: String) async throws -> Data?
    func write(_ data: Data, account: String) async throws
    func delete(account: String?) async throws
}

/// API used by the Mac publisher and iPhone reader. `current()` does not create
/// a key; only the explicitly named `loadOrCreate()` operation is allowed to do
/// that. A broken current pointer fails closed instead of silently minting a new
/// key that could make already-encrypted CloudKit data unreadable.
public protocol SyncKeyStoring: Sendable {
    func current() async throws -> SyncKeyRecord?
    func load(keyID: UUID) async throws -> SyncKeyRecord?
    func loadOrCreate() async throws -> SyncKeyRecord
    func rotate() async throws -> SyncKeyRecord
    func delete(keyID: UUID) async throws
    func deleteAll() async throws
}

/// Stores only the app's cross-device AES-256 key material in a distinct,
/// synchronizable generic-password service. Passing `accessGroup` is required
/// for a signed production build that uses a shared Keychain access group; it is
/// optional here so command-line unit tests can inject a fake client.
public actor SynchronizableSyncKeyStore: SyncKeyStoring {
    public static let service = "com.jamesli.tokenremain.sync-key"

    private static let currentPointerAccount = "current-v1"
    private static let keyAccountPrefix = "key-v1:"

    private let client: any SynchronizableKeychainClient

    public init(accessGroup: String? = nil) {
        self.client = SecuritySynchronizableKeychainClient(accessGroup: accessGroup)
    }

    public init(client: any SynchronizableKeychainClient) {
        self.client = client
    }

    public func current() async throws -> SyncKeyRecord? {
        guard let pointer = try await client.read(account: Self.currentPointerAccount) else {
            return nil
        }
        let keyID = try Self.decodePointer(pointer)
        guard let record = try await load(keyID: keyID) else {
            throw SyncKeyStoreError.currentKeyMissing(keyID)
        }
        return record
    }

    public func load(keyID: UUID) async throws -> SyncKeyRecord? {
        guard keyID != syncKeyStoreZeroUUID else {
            throw SyncKeyStoreError.invalidKeyID
        }
        guard let rawKey = try await client.read(account: Self.keyAccount(for: keyID)) else {
            return nil
        }
        do {
            return try SyncKeyRecord(keyID: keyID, rawKey: rawKey)
        } catch SyncProtocolError.invalidKeyLength(let count) {
            throw SyncKeyStoreError.invalidKeyMaterial(count)
        } catch let error as SyncKeyStoreError {
            throw error
        } catch {
            throw SyncKeyStoreError.invalidKeyMaterial(rawKey.count)
        }
    }

    public func loadOrCreate() async throws -> SyncKeyRecord {
        if let current = try await current() {
            return current
        }
        return try await makeCurrentKey()
    }

    /// Creates a fresh current key while retaining older key records. Retaining
    /// them lets a reader decrypt the existing fixed CloudKit record during a
    /// rotation race; the publisher may delete an obsolete key only after its
    /// replacement snapshot is known to be available.
    public func rotate() async throws -> SyncKeyRecord {
        try await makeCurrentKey()
    }

    public func delete(keyID: UUID) async throws {
        guard keyID != syncKeyStoreZeroUUID else {
            throw SyncKeyStoreError.invalidKeyID
        }
        if let pointer = try await client.read(account: Self.currentPointerAccount),
           try Self.decodePointer(pointer) == keyID {
            try await client.delete(account: Self.currentPointerAccount)
        }
        try await client.delete(account: Self.keyAccount(for: keyID))
    }

    /// Removes only items in this sync-key service. It cannot delete the
    /// provider-token Keychain entries owned by the rest of the application.
    public func deleteAll() async throws {
        do {
            try await client.delete(account: nil)
        } catch SyncKeyStoreError.itemNotFound {
            // Idempotent deletion is useful when the user disables sync on a
            // device that never received the synchronizable key.
        }
    }

    private func makeCurrentKey() async throws -> SyncKeyRecord {
        let record = try SyncKeyRecord(keyID: UUID(), key: .random())
        let keyAccount = Self.keyAccount(for: record.keyID)
        try await client.write(record.key.rawValue, account: keyAccount)
        do {
            try await client.write(Self.encodePointer(record.keyID), account: Self.currentPointerAccount)
        } catch {
            // Do not leave a newly-created orphan behind when writing the
            // current pointer fails. A deletion failure is intentionally not
            // allowed to mask the original, more actionable error.
            try? await client.delete(account: keyAccount)
            throw error
        }
        return record
    }

    private static func keyAccount(for keyID: UUID) -> String {
        "\(keyAccountPrefix)\(keyID.uuidString.lowercased())"
    }

    private static func encodePointer(_ keyID: UUID) -> Data {
        Data(keyID.uuidString.lowercased().utf8)
    }

    private static func decodePointer(_ data: Data) throws -> UUID {
        guard let value = String(data: data, encoding: .utf8),
              value.utf8.count == 36,
              let keyID = UUID(uuidString: value),
              keyID != syncKeyStoreZeroUUID else {
            throw SyncKeyStoreError.malformedCurrentPointer
        }
        return keyID
    }
}

/// Security-backed client. It deliberately has no API for arbitrary services,
/// so this sync component cannot be repurposed to read provider credentials.
public struct SecuritySynchronizableKeychainClient: SynchronizableKeychainClient, @unchecked Sendable {
    private let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup?.isEmpty == false ? accessGroup : nil
    }

    public func read(account: String) async throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SyncKeyStoreError.keychainFailure(status)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.map(status)
        }
    }

    public func write(_ data: Data, account: String) async throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw Self.map(addStatus)
        }

        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw Self.map(updateStatus)
        }
    }

    public func delete(account: String?) async throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw Self.map(status)
        }
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SynchronizableSyncKeyStore.service,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func map(_ status: OSStatus) -> SyncKeyStoreError {
        switch status {
        case errSecDuplicateItem:
            return .duplicateItem
        case errSecItemNotFound:
            return .itemNotFound
        case errSecMissingEntitlement:
            return .missingEntitlement
        case errSecInteractionNotAllowed:
            return .interactionNotAllowed
        case errSecNotAvailable:
            return .keychainUnavailable
        default:
            return .keychainFailure(status)
        }
    }
}

private let syncKeyStoreZeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
