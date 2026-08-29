import Foundation
import Security

struct KeychainSecretStore: Sendable {
    enum Accessibility: Sendable {
        case afterFirstUnlock
        case afterFirstUnlockThisDeviceOnly

        var securityValue: CFString {
            switch self {
            case .afterFirstUnlock:
                kSecAttrAccessibleAfterFirstUnlock
            case .afterFirstUnlockThisDeviceOnly:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    enum StoreError: LocalizedError {
        case invalidData
        case verificationFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidData:
                return L10n.text("keychain.unknown_error")
            case .verificationFailed:
                return L10n.text("keychain.verification_failed")
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? L10n.text("keychain.unknown_error")
                return L10n.format("keychain.operation_failed", detail)
            }
        }
    }

    enum ReadState: Equatable, Sendable {
        case missing
        case available(String)
        case authorizationRequired(OSStatus)
        case invalidData
        case failure(OSStatus)
    }

    struct Operations: @unchecked Sendable {
        let read: (String, String, KeychainRead.Interaction) -> KeychainRead.Outcome
        let update: ([String: Any], [String: Any]) -> OSStatus
        let add: ([String: Any]) -> OSStatus
        let delete: ([String: Any]) -> OSStatus

        static let system = Operations(
            read: { service, account, interaction in
                KeychainRead.genericPassword(
                    service: service,
                    account: account,
                    interaction: interaction
                )
            },
            update: { query, attributes in
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            add: { query in
                SecItemAdd(query as CFDictionary, nil)
            },
            delete: { query in
                SecItemDelete(query as CFDictionary)
            }
        )
    }

    let service: String
    let account: String
    let accessibility: Accessibility
    private let operations: Operations

    init(
        service: String,
        account: String,
        accessibility: Accessibility = .afterFirstUnlock,
        operations: Operations = .system
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
        self.operations = operations
    }

    /// 读取走统一入口。这些条目是 app 自己写的、ACL 天然信任自己,但"几乎不会
    /// 需要交互"不等于"不会阻塞",没有理由留一条能吊住调用方的裸读取。
    func read() throws -> String? {
        try read(interaction: .disallowed)
    }

    func read(interaction: KeychainRead.Interaction) throws -> String? {
        switch readState(interaction: interaction) {
        case .missing:
            return nil
        case .available(let value):
            return value
        case .authorizationRequired(let status), .failure(let status):
            throw StoreError.unexpectedStatus(status)
        case .invalidData:
            throw StoreError.invalidData
        }
    }

    func readState(interaction: KeychainRead.Interaction = .disallowed) -> ReadState {
        let outcome = operations.read(service, account, interaction)
        if outcome.status == errSecItemNotFound {
            return .missing
        }
        if outcome.needsAuthorization {
            return .authorizationRequired(outcome.status)
        }
        guard outcome.status == errSecSuccess else {
            return .failure(outcome.status)
        }
        guard let value = outcome.payload else {
            return .invalidData
        }
        return .available(value)
    }

    func save(_ value: String) throws {
        let attributes = valueAttributes(value)
        let updateStatus = operations.update(baseQuery, attributes)

        if updateStatus == errSecItemNotFound {
            var query = baseQuery
            query.merge(attributes) { _, new in new }
            let addStatus = operations.add(query)
            guard addStatus == errSecSuccess else {
                throw StoreError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw StoreError.unexpectedStatus(updateStatus)
        }
    }

    /// Recreates an app-owned item whose legacy ACL belongs to an older app
    /// signature. Callers must only use this after an explicit user action and
    /// after validating the replacement value, because the old item is deleted.
    func saveRebindingAuthorization(_ value: String) throws {
        switch readState() {
        case .authorizationRequired:
            let deleteStatus = operations.delete(baseQuery)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw StoreError.unexpectedStatus(deleteStatus)
            }
            var query = baseQuery
            query.merge(valueAttributes(value)) { _, new in new }
            let addStatus = operations.add(query)
            guard addStatus == errSecSuccess else {
                throw StoreError.unexpectedStatus(addStatus)
            }
        case .missing, .available:
            try save(value)
        case .invalidData:
            throw StoreError.invalidData
        case .failure(let status):
            throw StoreError.unexpectedStatus(status)
        }

        guard case .available(let savedValue) = readState(), savedValue == value else {
            throw StoreError.verificationFailed
        }
    }

    func delete() throws {
        let status = operations.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }

    var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // This store never reads or mutates a synchronizable item. The
            // explicit selector prevents a pre-existing synced item with the
            // same service/account from weakening a ThisDeviceOnly caller.
            kSecAttrSynchronizable as String: false,
        ]
    }

    func valueAttributes(_ value: String) -> [String: Any] {
        [
            kSecValueData as String: Data(value.utf8),
            // Reassert the requested protection class on updates as well as
            // creation; otherwise SecItemUpdate would retain an older class.
            kSecAttrAccessible as String: accessibility.securityValue,
        ]
    }
}
