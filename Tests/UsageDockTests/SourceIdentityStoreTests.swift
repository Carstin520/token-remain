import Foundation
import Security
import Testing
@testable import UsageDock

private final class InMemorySourceIdentityKeychain: SourceIdentityKeychainStoring {
    var storedValue: String?
    var savedValues: [String] = []
    var deleteCount = 0

    init(storedValue: String? = nil) {
        self.storedValue = storedValue
    }

    func read() throws -> String? {
        storedValue
    }

    func save(_ value: String) throws {
        storedValue = value
        savedValues.append(value)
    }

    func delete() throws {
        storedValue = nil
        deleteCount += 1
    }
}

@Suite("Cross-device source identity")
struct SourceIdentityStoreTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "TokenRemainSourceIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test("Legacy UserDefaults identity migrates once into device-local storage")
    func migratesLegacyIdentifier() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
        defaults.set(legacy.uuidString, forKey: SourceIdentityStore.legacyDefaultsKey)
        let keychain = InMemorySourceIdentityKeychain()
        let generated = UUID(uuidString: "00000000-0000-4000-8000-000000000012")!
        let store = SourceIdentityStore(
            defaults: defaults,
            keychain: keychain,
            makeIdentifier: { generated }
        )

        #expect(try store.loadOrCreate() == legacy)
        #expect(keychain.savedValues == [legacy.uuidString.lowercased()])
        #expect(defaults.object(forKey: SourceIdentityStore.legacyDefaultsKey) == nil)
        #expect(try store.loadOrCreate() == legacy)
        #expect(keychain.savedValues.count == 1)
    }

    @Test("Identity Keychain writes explicitly remain local to this device")
    func keychainAttributesStayDeviceLocal() {
        let store = KeychainSecretStore(
            service: SourceIdentityStore.service,
            account: SourceIdentityStore.account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        let attributes = store.valueAttributes(UUID().uuidString)

        #expect(store.baseQuery[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(
            attributes[kSecAttrAccessible as String] as? String ==
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @Test("Fresh identity is generated once and then remains stable")
    func generatesStableIdentifier() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let generated = UUID(uuidString: "00000000-0000-4000-8000-000000000013")!
        let keychain = InMemorySourceIdentityKeychain()
        let store = SourceIdentityStore(
            defaults: defaults,
            keychain: keychain,
            makeIdentifier: { generated }
        )

        #expect(try store.loadOrCreate() == generated)
        #expect(try store.loadOrCreate() == generated)
        #expect(keychain.savedValues == [generated.uuidString.lowercased()])
    }

    @Test("Malformed Keychain identity fails closed")
    func rejectsMalformedStoredIdentifier() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = InMemorySourceIdentityKeychain(storedValue: "not-a-uuid")
        let store = SourceIdentityStore(
            defaults: defaults,
            keychain: keychain,
            makeIdentifier: UUID.init
        )

        #expect(throws: SourceIdentityStoreError.invalidStoredIdentifier) {
            try store.loadOrCreate()
        }
        #expect(keychain.savedValues.isEmpty)
    }

    @Test("Reset removes both current and legacy identity state")
    func resetsIdentity() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(UUID().uuidString, forKey: SourceIdentityStore.legacyDefaultsKey)
        let keychain = InMemorySourceIdentityKeychain(storedValue: UUID().uuidString)
        let store = SourceIdentityStore(
            defaults: defaults,
            keychain: keychain,
            makeIdentifier: UUID.init
        )

        try store.delete()

        #expect(keychain.deleteCount == 1)
        #expect(keychain.storedValue == nil)
        #expect(defaults.object(forKey: SourceIdentityStore.legacyDefaultsKey) == nil)
    }
}
