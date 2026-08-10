import Foundation

/// One routing point for managed provider accounts. Provider-specific clients
/// receive an explicit credential and therefore cannot accidentally fall back
/// to another account's global environment, config file, IPC session or keychain.
struct ProviderAccountFetchService: Sendable {
    enum FetchError: LocalizedError {
        case unsupportedProvider(String)
        case missingProfileDirectory
        case missingCredential

        var errorDescription: String? {
            switch self {
            case .unsupportedProvider(let provider):
                "\(provider) does not expose a safe multi-account credential boundary."
            case .missingProfileDirectory:
                "The isolated account profile is missing. Remove it and sign in again."
            case .missingCredential:
                "This account has no saved credential."
            }
        }
    }

    func fetch(_ profile: ProviderAccountProfile, now: Date = .now) async throws -> ProviderQuota {
        guard !profile.isSystem else {
            throw FetchError.unsupportedProvider(profile.provider.displayName)
        }

        switch profile.provider {
        case .claude:
            return try await ClaudeUsageService(
                configurationDirectory: try configurationDirectory(profile)
            ).fetch(forceScopedUsageProbe: true)
        case .codex:
            return try await CodexAPIUsageService().fetch(
                now: now,
                configurationDirectory: try configurationDirectory(profile)
            )
        case .cursor:
            let credential = try secret(profile)
            return try await CursorUsageService().fetch(
                accessToken: credential.value,
                membershipType: credential.field("membershipType"),
                now: now
            )
        case .grok:
            return try await GrokUsageService().fetch(token: try secret(profile).value, now: now)
        case .zai:
            let credential = try secret(profile)
            let region = credential.field("region").flatMap(ZAIAPIRegion.parse)
                ?? ZAIRegionStore().load()
            return try await ZAIUsageService().fetch(
                apiKey: credential.value,
                region: region,
                now: now
            )
        case .zaiTeam:
            return try await ZAITeamUsageService().fetch(
                configuration: try secret(profile).raw,
                now: now
            )
        case .copilot:
            return try await CopilotUsageService().fetch(token: try secret(profile).value, now: now)
        case .devin:
            let credential = try secret(profile)
            return try await DevinUsageService().fetch(
                apiKey: credential.value,
                apiServerURL: credential.field("apiServerURL"),
                now: now
            )
        case .windsurf:
            let credential = try secret(profile)
            return try await WindsurfUsageService().fetch(
                apiKey: credential.value,
                apiServerURL: credential.field("apiServerURL"),
                now: now
            )
        case .openrouter:
            return try await OpenRouterUsageService().fetch(apiKey: try secret(profile).value, now: now)
        case .antigravity:
            return try await AntigravityUsageService().fetch(
                accessToken: try secret(profile).value,
                now: now
            )
        case .deepseek:
            return try await DeepSeekUsageService().fetch(apiKey: try secret(profile).value, now: now)
        case .kimi:
            return try await KimiUsageService().fetch(secret: try secret(profile).value, now: now)
        case .minimax:
            return try await MiniMaxUsageService().fetch(apiKey: try secret(profile).value, now: now)
        case .mimo:
            return try await MiMoUsageService().fetch(cookie: try secret(profile).value, now: now)
        case .qoder:
            return try await QoderUsageService().fetch(cookie: try secret(profile).value, now: now)
        case .volcengine:
            return try await VolcengineUsageService().fetch(
                credentials: try secret(profile).value,
                now: now
            )
        case .ollama:
            return try await OllamaUsageService().fetch(cookie: try secret(profile).value, now: now)
        case .thirdParty:
            return try await ThirdPartyUsageService().fetch(
                configuration: try secret(profile).raw,
                now: now
            )
        case .opencode, .kiro:
            throw FetchError.unsupportedProvider(profile.provider.displayName)
        }
    }

    private func configurationDirectory(_ profile: ProviderAccountProfile) throws -> URL {
        guard let path = profile.configurationDirectory else {
            throw FetchError.missingProfileDirectory
        }
        return URL(fileURLWithPath: path)
    }

    private func secret(_ profile: ProviderAccountProfile) throws -> Credential {
        guard let raw = ProviderAccountSecretStore(
            provider: profile.provider,
            accountID: profile.id
        ).load() else {
            throw FetchError.missingCredential
        }
        return Credential(raw: raw)
    }
}

private struct Credential {
    let raw: String
    let object: [String: Any]?

    init(raw: String) {
        self.raw = raw
        if let data = raw.data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else {
            object = nil
        }
    }

    var value: String {
        for key in ["value", "token", "apiKey", "api_key", "key", "cookie"] {
            if let field = field(key) { return field }
        }
        return raw
    }

    func field(_ key: String) -> String? {
        guard let value = (object?[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
