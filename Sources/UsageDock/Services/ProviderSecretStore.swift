import Foundation

/// 需要用户提供密钥/Cookie 的 provider 的通用凭据仓库(token-monitor 式
/// 兼容层)。读取顺序:环境变量 → 用户在「数据源」页粘贴入钥匙串的值。
/// 保存/清除只操作钥匙串;值可以是 API Key、AK:SK 组合或整段 Cookie。
struct ProviderSecretStore {
    struct Descriptor {
        let provider: ProviderQuota.Provider
        /// 依序尝试的环境变量名。
        let envKeys: [String]
        /// 「数据源」页输入框的占位提示。
        let placeholder: String
        /// true = Cookie(整段粘贴),false = API Key / AK:SK。
        let isCookie: Bool
    }

    /// token-monitor 兼容的密钥/Cookie 型 provider 目录(Z.ai / OpenRouter
    /// 已有专用 store,不在此列)。
    static let descriptors: [Descriptor] = [
        Descriptor(provider: .deepseek,
                   envKeys: ["DEEPSEEK_API_KEY"],
                   placeholder: L10n.text("secret.placeholder.deepseek"),
                   isCookie: false),
        Descriptor(provider: .kimi,
                   envKeys: ["KIMI_CODE_API_KEY", "KIMI_API_KEY"],
                   placeholder: L10n.text("secret.placeholder.kimi"),
                   isCookie: false),
        Descriptor(provider: .minimax,
                   envKeys: ["MINIMAX_API_KEY"],
                   placeholder: L10n.text("secret.placeholder.minimax"),
                   isCookie: false),
        Descriptor(provider: .mimo,
                   envKeys: ["MIMO_COOKIE"],
                   placeholder: L10n.text("secret.placeholder.mimo"),
                   isCookie: true),
        Descriptor(provider: .qoder,
                   envKeys: ["QODER_COOKIE"],
                   placeholder: L10n.text("secret.placeholder.qoder"),
                   isCookie: true),
        Descriptor(provider: .volcengine,
                   envKeys: ["VOLCENGINE_ACCESS_KEY"],
                   placeholder: L10n.text("secret.placeholder.volcengine"),
                   isCookie: false),
        Descriptor(provider: .ollama,
                   envKeys: ["OLLAMA_COOKIE"],
                   placeholder: L10n.text("secret.placeholder.ollama"),
                   isCookie: true),
        Descriptor(provider: .zaiTeam,
                   envKeys: ["TOKENREMAIN_ZAI_TEAM_CONFIG"],
                   placeholder: L10n.text("secret.placeholder.zai_team"),
                   isCookie: false),
        Descriptor(provider: .thirdParty,
                   envKeys: ["TOKENREMAIN_THIRD_PARTY_CONFIG"],
                   placeholder: L10n.text("secret.placeholder.third_party"),
                   isCookie: false)
    ]

    static func descriptor(for provider: ProviderQuota.Provider) -> Descriptor? {
        descriptors.first { $0.provider == provider }
    }

    let provider: ProviderQuota.Provider
    var environment: [String: String] = ProcessInfo.processInfo.environment

    private var keychain: KeychainSecretStore {
        KeychainSecretStore(
            service: "com.jamesli.usagedock.\(provider.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
            account: "secret"
        )
    }

    func load() -> String? {
        if let descriptor = Self.descriptor(for: provider) {
            for key in descriptor.envKeys {
                if let value = normalized(environment[key]) { return value }
            }
        }
        return normalized((try? keychain.read()) ?? nil)
    }

    func hasStoredSecret() -> Bool {
        normalized((try? keychain.read()) ?? nil) != nil
    }

    func save(_ value: String) throws {
        try keychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func clear() throws {
        try keychain.delete()
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
