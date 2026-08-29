import Foundation
import Security
import Testing

@testable import UsageDock

@Suite("App-owned Keychain isolation and repair")
struct AppOwnedKeychainTests {
    private final class FakeItem {
        var requiresAuthorization = true
        var value: String?
        var steps: [String] = []
    }

    @Test("Production keeps historical services while development uses its own namespace")
    func namespaceIsolation() {
        let production = AppOwnedKeychainNamespace(
            bundleIdentifier: "com.jamesli.usagedock"
        )
        let development = AppOwnedKeychainNamespace(
            bundleIdentifier: "com.jamesli.usagedock.dev"
        )
        let unrelated = AppOwnedKeychainNamespace(bundleIdentifier: "org.swift.swiftpm")

        #expect(production.service("deepseek") == "com.jamesli.usagedock.deepseek")
        #expect(development.service("deepseek") == "com.jamesli.usagedock.dev.deepseek")
        #expect(unrelated.service("deepseek") == "com.jamesli.usagedock.deepseek")
    }

    @Test("Authorization denial is not reported as a missing credential")
    func readStateDistinguishesAuthorizationFromAbsence() {
        let authorized = makeStore(readStatus: errSecAuthFailed)
        let missing = makeStore(readStatus: errSecItemNotFound)
        let failed = makeStore(readStatus: errSecNotAvailable)

        #expect(authorized.readState() == .authorizationRequired(errSecAuthFailed))
        #expect(missing.readState() == .missing)
        #expect(failed.readState() == .failure(errSecNotAvailable))
    }

    @Test("Replacing a stale ACL deletes and recreates the item, then verifies it silently")
    func staleAuthorizationIsReboundAndVerified() throws {
        let item = FakeItem()
        let operations = KeychainSecretStore.Operations(
            read: { _, _, _ in
                item.steps.append("read")
                if item.requiresAuthorization {
                    return KeychainRead.Outcome(payload: nil, status: errSecAuthFailed)
                }
                guard let value = item.value else {
                    return KeychainRead.Outcome(payload: nil, status: errSecItemNotFound)
                }
                return KeychainRead.Outcome(payload: value, status: errSecSuccess)
            },
            update: { _, _ in
                item.steps.append("update")
                return errSecItemNotFound
            },
            add: { query in
                item.steps.append("add")
                guard let data = query[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8) else {
                    return errSecParam
                }
                item.requiresAuthorization = false
                item.value = value
                return errSecSuccess
            },
            delete: { _ in
                item.steps.append("delete")
                item.requiresAuthorization = false
                item.value = nil
                return errSecSuccess
            }
        )
        let store = KeychainSecretStore(
            service: "com.jamesli.usagedock.test",
            account: "secret",
            operations: operations
        )

        try store.saveRebindingAuthorization("replacement")

        #expect(item.value == "replacement")
        #expect(item.steps == ["read", "delete", "add", "read"])
    }

    private func makeStore(readStatus: OSStatus) -> KeychainSecretStore {
        KeychainSecretStore(
            service: "com.jamesli.usagedock.test",
            account: "secret",
            operations: KeychainSecretStore.Operations(
                read: { _, _, _ in
                    KeychainRead.Outcome(payload: nil, status: readStatus)
                },
                update: { _, _ in errSecSuccess },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            )
        )
    }
}
