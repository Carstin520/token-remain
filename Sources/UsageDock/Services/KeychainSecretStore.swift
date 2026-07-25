import Foundation
import Security

struct KeychainSecretStore: Sendable {
    enum StoreError: LocalizedError {
        case invalidData
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidData:
                return L10n.text("keychain.unknown_error")
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? L10n.text("keychain.unknown_error")
                return L10n.format("keychain.operation_failed", detail)
            }
        }
    }

    let service: String
    let account: String

    /// 读取走统一入口。这些条目是 app 自己写的、ACL 天然信任自己,但"几乎不会
    /// 需要交互"不等于"不会阻塞",没有理由留一条能吊住调用方的裸读取。
    func read() throws -> String? {
        let outcome = KeychainRead.genericPassword(
            service: service,
            account: account,
            interaction: .disallowed
        )
        if outcome.status == errSecItemNotFound {
            return nil
        }
        guard outcome.status == errSecSuccess else {
            throw StoreError.unexpectedStatus(outcome.status)
        }
        guard let value = outcome.payload else {
            throw StoreError.invalidData
        }
        return value
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StoreError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw StoreError.unexpectedStatus(updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
