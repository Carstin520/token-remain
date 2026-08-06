import Foundation

/// A resolved quota route for an AI host application. Credentials live only in
/// this transient value and are never copied into `ProviderQuota` or its cache.
struct HostAppQuotaRoute: Sendable, Equatable {
    let hostProvider: ProviderQuota.Provider
    let source: QuotaAttribution?
    let baseURL: URL?
    let credential: String?

    var isExternal: Bool { source != nil }
}

struct HostAppQuotaRoutingError: LocalizedError, Sendable {
    let sourceName: String
    let underlyingDescription: String

    var errorDescription: String? {
        "\(sourceName): \(underlyingDescription)"
    }
}

/// Detects the account behind Claude Code and Codex without changing either
/// application's identity in TokenRemain. Detection is deliberately read-only:
/// it consumes the same user-level routing settings as each CLI and never
/// writes, migrates, or logs credentials.
struct HostAppQuotaRouteDetector: Sendable {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func route(for hostProvider: ProviderQuota.Provider) -> HostAppQuotaRoute {
        switch hostProvider {
        case .claude:
            return claudeRoute()
        case .codex:
            return codexRoute()
        default:
            return HostAppQuotaRoute(
                hostProvider: hostProvider,
                source: nil,
                baseURL: nil,
                credential: nil
            )
        }
    }

    private func claudeRoute() -> HostAppQuotaRoute {
        let settingsURL = claudeSettingsURL()
        var settings = Self.claudeSettingsEnvironment(
            at: settingsURL,
            fileManager: .default
        )
        settings.merge(
            Self.claudeSettingsEnvironment(
                at: settingsURL.deletingLastPathComponent().appending(path: "settings.local.json"),
                fileManager: .default
            ),
            uniquingKeysWith: { _, local in local }
        )
        let baseText = normalized(environment["ANTHROPIC_BASE_URL"])
            ?? normalized(settings["ANTHROPIC_BASE_URL"])
        let credential = normalized(environment["ANTHROPIC_AUTH_TOKEN"])
            ?? normalized(environment["ANTHROPIC_API_KEY"])
            ?? normalized(settings["ANTHROPIC_AUTH_TOKEN"])
            ?? normalized(settings["ANTHROPIC_API_KEY"])
        guard let baseText else {
            return HostAppQuotaRoute(
                hostProvider: .claude,
                source: nil,
                baseURL: nil,
                credential: nil
            )
        }
        guard let baseURL = Self.normalizedBaseURL(baseText) else {
            return Self.externalRoute(
                hostProvider: .claude,
                providerID: "configured-relay",
                baseURL: nil,
                credential: credential
            )
        }
        guard !Self.isOfficialClaudeURL(baseURL) else {
            return HostAppQuotaRoute(
                hostProvider: .claude,
                source: nil,
                baseURL: nil,
                credential: nil
            )
        }
        return Self.externalRoute(
            hostProvider: .claude,
            providerID: nil,
            baseURL: baseURL,
            credential: credential
        )
    }

    private func codexRoute() -> HostAppQuotaRoute {
        let codexHome = codexHomeDirectory()
        let configURL = codexHome.appending(path: "config.toml")
        let text = try? String(contentsOf: configURL, encoding: .utf8)
        let configuration = Self.parseCodexConfiguration(text ?? "")
        let auth = Self.codexAuthentication(at: codexHome.appending(path: "auth.json"))
        let providerID = normalized(configuration.modelProvider) ?? "openai"
        let provider = configuration.providers[providerID]
        let baseText = normalized(environment["OPENAI_BASE_URL"])
            ?? normalized(configuration.openAIBaseURL)
            ?? normalized(provider?.baseURL)
        let baseURL = baseText.flatMap(Self.normalizedBaseURL)
        let credential = provider?.environmentKey.flatMap { normalized(environment[$0]) }
            ?? (providerID.caseInsensitiveCompare("openai") == .orderedSame
                ? normalized(environment["OPENAI_API_KEY"]) ?? auth.apiKey
                : nil)
        let isOpenAIProvider = providerID.caseInsensitiveCompare("openai") == .orderedSame
        let prefersAPIKey = isOpenAIProvider && (
            configuration.preferredAuthMethod?.caseInsensitiveCompare("apikey") == .orderedSame
                || (credential != nil && !auth.hasChatGPTAccessToken)
        )

        let hasOfficialOrUnsetBaseURL = baseText == nil
            || baseURL.map(Self.isOfficialCodexURL) == true
        if isOpenAIProvider,
           !prefersAPIKey,
           hasOfficialOrUnsetBaseURL {
            return HostAppQuotaRoute(
                hostProvider: .codex,
                source: nil,
                baseURL: nil,
                credential: nil
            )
        }
        return Self.externalRoute(
            hostProvider: .codex,
            providerID: baseText != nil && baseURL == nil
                ? "configured-relay"
                : (prefersAPIKey ? "openai-api" : providerID),
            baseURL: baseURL ?? (baseText == nil && prefersAPIKey
                ? URL(string: "https://api.openai.com")
                : nil),
            credential: credential
        )
    }

    private func codexHomeDirectory() -> URL {
        guard let custom = normalized(environment["CODEX_HOME"]) else {
            return homeDirectory.appending(path: ".codex")
        }
        let expanded = (custom as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return homeDirectory.appending(path: expanded)
    }

    private func claudeSettingsURL() -> URL {
        if let custom = normalized(environment["CLAUDE_CONFIG_DIR"]) {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .appending(path: "settings.json")
        }
        return homeDirectory.appending(path: ".claude/settings.json")
    }

    static func claudeSettingsEnvironment(
        at url: URL,
        fileManager: FileManager = .default
    ) -> [String: String] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = object["env"] as? [String: Any] else {
            return [:]
        }
        return values.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            }
        }
    }

    struct CodexProviderConfiguration: Sendable, Equatable {
        var baseURL: String?
        var environmentKey: String?
    }

    struct CodexConfiguration: Sendable, Equatable {
        var modelProvider: String?
        var openAIBaseURL: String?
        var preferredAuthMethod: String?
        var providers: [String: CodexProviderConfiguration] = [:]
    }

    /// Narrow TOML reader for the documented Codex routing keys. Keeping this
    /// parser scoped avoids adding a dependency just to read three strings, but
    /// still handles quoted values, comments, and provider sections.
    static func parseCodexConfiguration(_ text: String) -> CodexConfiguration {
        var result = CodexConfiguration()
        var providerSection: String?
        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let line = stripTOMLComment(String(rawLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "model_providers."
                providerSection = section.hasPrefix(prefix)
                    ? String(section.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    : nil
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = tomlString(rawValue) else { continue }
            if let providerSection {
                var provider = result.providers[providerSection] ?? CodexProviderConfiguration()
                if key == "base_url" { provider.baseURL = value }
                if key == "env_key" { provider.environmentKey = value }
                result.providers[providerSection] = provider
            } else {
                if key == "model_provider" { result.modelProvider = value }
                if key == "openai_base_url" { result.openAIBaseURL = value }
                if key == "preferred_auth_method" { result.preferredAuthMethod = value }
            }
        }
        return result
    }

    struct CodexAuthentication: Sendable, Equatable {
        let apiKey: String?
        let hasChatGPTAccessToken: Bool
    }

    static func codexAuthentication(at url: URL) -> CodexAuthentication {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexAuthentication(apiKey: nil, hasChatGPTAccessToken: false)
        }
        let apiKey = normalized(root["OPENAI_API_KEY"] as? String)
            ?? normalized(root["api_key"] as? String)
        let tokens = root["tokens"] as? [String: Any]
        let accessToken = normalized(tokens?["access_token"] as? String)
        return CodexAuthentication(
            apiKey: apiKey,
            hasChatGPTAccessToken: accessToken != nil
        )
    }

    private static func stripTOMLComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func tomlString(_ value: String) -> String? {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" || first == "'"), last == first else {
            return nil
        }
        let inner = String(value.dropFirst().dropLast())
        if first == "'" { return inner }
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func externalRoute(
        hostProvider: ProviderQuota.Provider,
        providerID: String?,
        baseURL: URL?,
        credential: String?
    ) -> HostAppQuotaRoute {
        let classified = classify(providerID: providerID, baseURL: baseURL)
        let host = baseURL?.host?.lowercased()
        let providerRouteKey = providerID?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(64)
        let routeIdentifier = [
            hostProvider.rawValue.lowercased(),
            classified.provider?.rawValue.lowercased() ?? "external",
            host ?? providerRouteKey.map(String.init) ?? "unknown"
        ].joined(separator: "|")
        return HostAppQuotaRoute(
            hostProvider: hostProvider,
            source: QuotaAttribution(
                provider: classified.provider,
                displayName: classified.displayName,
                routeIdentifier: routeIdentifier
            ),
            baseURL: baseURL,
            credential: credential
        )
    }

    static func classify(
        providerID: String?,
        baseURL: URL?
    ) -> (provider: ProviderQuota.Provider?, displayName: String) {
        let host = baseURL?.host?.lowercased() ?? ""
        let id = providerID?.lowercased() ?? ""
        let known: [(ProviderQuota.Provider, ids: [String], domains: [String])] = [
            (.deepseek, ["deepseek"], ["deepseek.com"]),
            (.openrouter, ["openrouter"], ["openrouter.ai"]),
            (.zai, ["zai", "z.ai", "bigmodel", "zhipu"], ["z.ai", "bigmodel.cn", "zhipuai.cn"]),
            (.kimi, ["kimi", "moonshot"], ["kimi.com", "moonshot.cn"]),
            (.minimax, ["minimax"], ["minimax.io", "minimaxi.com"]),
            (.mimo, ["mimo", "xiaomi"], ["xiaomi.com"])
        ]
        // A concrete hostname is authoritative. A custom relay named
        // "deepseek-proxy" is billed by that relay, not api.deepseek.com.
        if !host.isEmpty {
            if (host == "api.openai.com" || host.hasSuffix(".openai.com")),
               id.contains("openai") {
                return (.thirdParty, "OpenAI API")
            }
            for (provider, _, domains) in known where domains.contains(where: {
                host == $0 || host.hasSuffix(".\($0)")
            }) {
                return (provider, "\(provider.displayName) API")
            }
            return (.thirdParty, host)
        }
        for (provider, ids, _) in known where ids.contains(id) {
            return (provider, "\(provider.displayName) API")
        }
        let fallback = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(64)
        return (.thirdParty, fallback.map { "\($0) API" } ?? "Third-party API")
    }

    static func normalizedBaseURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        components.fragment = nil
        return components.url
    }

    private static func isOfficialClaudeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")
    }

    private static func isOfficialCodexURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "api.openai.com" || host.hasSuffix(".openai.com")
            || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    }

    private func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }

    private static func normalized(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty ? nil : result
    }
}

/// Fetches the quota belonging to the resolved API route, then re-hosts it for
/// presentation under Claude Code or Codex. An external route never falls back
/// to the host's official subscription endpoint or local official snapshots.
struct HostAppQuotaRoutingService: Sendable {
    var detector: HostAppQuotaRouteDetector = HostAppQuotaRouteDetector()

    func route(for hostProvider: ProviderQuota.Provider) -> HostAppQuotaRoute {
        detector.route(for: hostProvider)
    }

    func fetchClaude() async throws -> ProviderQuota {
        let route = detector.route(for: .claude)
        guard route.isExternal else { return try await ClaudeUsageService().fetch() }
        return try await fetchExternal(route)
    }

    func fetchCodex(preferAPI: Bool) async throws -> ProviderQuota {
        let route = detector.route(for: .codex)
        guard route.isExternal else {
            return try await CodexUsageService().fetch(preferAPI: preferAPI)
        }
        return try await fetchExternal(route)
    }

    func fetchExternal(_ route: HostAppQuotaRoute) async throws -> ProviderQuota {
        guard let source = route.source, let provider = source.provider else {
            throw HostAppQuotaRoutingError(
                sourceName: route.source?.displayName ?? "Third-party API",
                underlyingDescription: L10n.text("service.third_party.config_incomplete")
            )
        }
        do {
            let quota: ProviderQuota = switch provider {
            case .deepseek:
                try await DeepSeekUsageService().fetch(apiKey: route.credential)
            case .openrouter:
                try await OpenRouterUsageService().fetch(apiKey: route.credential)
            case .zai:
                try await ZAIUsageService().fetch(
                    apiKey: route.credential,
                    region: route.baseURL.flatMap { ZAIAPIRegion.parse($0.absoluteString) }
                )
            case .kimi:
                try await KimiUsageService().fetch(secret: route.credential)
            case .minimax:
                try await MiniMaxUsageService().fetch(apiKey: route.credential)
            case .mimo:
                // MiMo's coding route token is not the console cookie required
                // by its balance API. Never substitute a separately stored
                // cookie account and misattribute that wallet to this route.
                throw ExtendedProviderError.invalidSecret(
                    .mimo,
                    detail: L10n.text("service.third_party.config_incomplete")
                )
            case .thirdParty:
                try await fetchThirdParty(matching: route.baseURL)
            default:
                throw ExtendedProviderError.notConfigured(provider)
            }
            return quota.attributed(to: route.hostProvider, source: source)
        } catch {
            throw HostAppQuotaRoutingError(
                sourceName: source.displayName,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func fetchThirdParty(matching routeBaseURL: URL?) async throws -> ProviderQuota {
        guard let configuration = ThirdPartyConfiguration.load(),
              Self.thirdPartyConfiguration(configuration, matches: routeBaseURL) else {
            throw ExtendedProviderError.invalidSecret(
                .thirdParty,
                detail: L10n.text("service.third_party.config_incomplete")
            )
        }
        return try await ThirdPartyUsageService().fetch()
    }

    static func thirdPartyConfiguration(
        _ configuration: ThirdPartyConfiguration,
        matches routeBaseURL: URL?
    ) -> Bool {
        guard let routeHost = routeBaseURL?.host?.lowercased(),
              let configuredHost = configuration.baseURL.host?.lowercased() else {
            return false
        }
        return configuredHost == routeHost
    }
}
