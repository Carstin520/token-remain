import Foundation

enum SourceIdentityStoreError: Error, Equatable {
    case invalidStoredIdentifier
}

protocol SourceIdentityKeychainStoring {
    func read() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

extension KeychainSecretStore: SourceIdentityKeychainStoring {}

/// Owns the stable, device-local identity used to order this Mac's sync writes.
///
/// The identity intentionally does not use the synchronizable sync-key access
/// group. Copying one source ID to another Mac would make independent writers
/// share a replay sequence and turn a safe per-device LWW record into a race.
struct SourceIdentityStore {
    static let service = "com.jamesli.usagedock.private-sync.identity"
    static let account = "source-instance-id.v1"
    static let legacyDefaultsKey = "crossDeviceSync.sourceInstanceID"

    private let defaults: UserDefaults
    private let keychain: any SourceIdentityKeychainStoring
    private let makeIdentifier: () -> UUID

    init(defaults: UserDefaults) {
        self.init(
            defaults: defaults,
            keychain: KeychainSecretStore(
                service: AppOwnedKeychainNamespace.current.service("private-sync.identity"),
                account: Self.account,
                accessibility: .afterFirstUnlockThisDeviceOnly
            ),
            makeIdentifier: UUID.init
        )
    }

    init(
        defaults: UserDefaults,
        keychain: any SourceIdentityKeychainStoring,
        makeIdentifier: @escaping () -> UUID
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.makeIdentifier = makeIdentifier
    }

    /// Loads the Keychain identity, or migrates the pre-v1.2 UserDefaults UUID
    /// before creating a new one. The legacy value is removed only after the
    /// device-local Keychain write succeeds. This migration is intentionally
    /// one-way: retaining a copyable defaults fallback would let a later Mac
    /// clone reuse this device identity.
    func loadOrCreate() throws -> UUID {
        if let existing = try loadExisting() {
            return existing
        }

        let identifier = makeIdentifier()
        try keychain.save(identifier.uuidString.lowercased())
        return identifier
    }

    /// Reads an existing identity without creating a phantom source merely to
    /// render management UI or attempt a disconnect. A pre-v1.2 defaults value
    /// is migrated through the same device-local Keychain boundary.
    func loadExisting() throws -> UUID? {
        if let storedValue = try keychain.read() {
            guard let identifier = UUID(uuidString: storedValue) else {
                throw SourceIdentityStoreError.invalidStoredIdentifier
            }
            removeLegacyIdentifier()
            return identifier
        }

        guard let legacyValue = defaults.string(forKey: Self.legacyDefaultsKey) else {
            return nil
        }
        guard let identifier = UUID(uuidString: legacyValue) else {
            throw SourceIdentityStoreError.invalidStoredIdentifier
        }
        try keychain.save(identifier.uuidString.lowercased())
        removeLegacyIdentifier()
        return identifier
    }

    func delete() throws {
        try keychain.delete()
        removeLegacyIdentifier()
    }

    private func removeLegacyIdentifier() {
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }
}
