import Foundation
import LocalAuthentication
import Security

/// 只读钥匙串工具:按 service(可选 account)取第一条 generic password。
/// 供各 provider 的凭证发现使用;绝不写入。
enum KeychainRead {
    static func genericPassword(
        service: String,
        account: String? = nil,
        allowUserInteraction: Bool = true
    ) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // Background quota refreshes must never summon a system password dialog.
        // A pre-authorized item still succeeds; an item that needs interaction
        // fails immediately so the caller can use a prompt-free fallback.
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// go-keyring(gh CLI、Antigravity 等 Go 工具的钥匙串库)会把较长的值
/// 包成 `go-keyring-base64:<b64>`;短值原样存放。
enum GoKeyring {
    static let base64Prefix = "go-keyring-base64:"

    static func unwrap(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(base64Prefix) else {
            return trimmed.isEmpty ? nil : trimmed
        }
        let encoded = String(trimmed.dropFirst(base64Prefix.count))
        guard let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
