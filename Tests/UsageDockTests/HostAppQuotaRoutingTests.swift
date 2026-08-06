import Foundation
import Testing
@testable import UsageDock

@Suite("Host app quota routing")
struct HostAppQuotaRoutingTests {
    @Test("Claude Code keeps its identity while DeepSeek owns the balance")
    func claudeDeepSeekRoute() throws {
        let detector = HostAppQuotaRouteDetector(
            homeDirectory: URL(fileURLWithPath: "/tmp/unused-home"),
            environment: [
                "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
                "ANTHROPIC_AUTH_TOKEN": "secret-never-cache"
            ]
        )

        let route = detector.route(for: .claude)

        #expect(route.hostProvider == .claude)
        #expect(route.source?.provider == .deepseek)
        #expect(route.source?.displayName == "DeepSeek API")
        #expect(route.credential == "secret-never-cache")
        #expect(route.source?.routeIdentifier.contains("secret-never-cache") == false)
    }

    @Test("Claude Code official endpoint remains official")
    func claudeOfficialRoute() {
        let detector = HostAppQuotaRouteDetector(
            homeDirectory: URL(fileURLWithPath: "/tmp/unused-home"),
            environment: ["ANTHROPIC_BASE_URL": "https://api.anthropic.com"]
        )
        #expect(detector.route(for: .claude).source == nil)
    }

    @Test("Claude Code settings env supplies the routed API credential")
    func claudeSettingsRoute() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(
            at: temporary.appending(path: ".claude"),
            withIntermediateDirectories: true
        )
        try #"{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}"#
            .write(
                to: temporary.appending(path: ".claude/settings.json"),
                atomically: true,
                encoding: .utf8
            )
        try #"{"env":{"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic","ANTHROPIC_AUTH_TOKEN":"settings-key"}}"#
            .write(
                to: temporary.appending(path: ".claude/settings.local.json"),
                atomically: true,
                encoding: .utf8
            )
        let route = HostAppQuotaRouteDetector(
            homeDirectory: temporary,
            environment: [:]
        ).route(for: .claude)

        #expect(route.source?.provider == .deepseek)
        #expect(route.credential == "settings-key")
    }

    @Test("A relay hostname wins over a provider-like config name")
    func relayClassificationDoesNotImpersonateDeepSeek() {
        let result = HostAppQuotaRouteDetector.classify(
            providerID: "deepseek-proxy",
            baseURL: URL(string: "https://relay.example.com/v1")
        )
        #expect(result.provider == .thirdParty)
        #expect(result.displayName == "relay.example.com")
        #expect(
            HostAppQuotaRouteDetector.classify(
                providerID: nil,
                baseURL: URL(string: "https://api.deepseek.com.evil.example/v1")
            ).provider == .thirdParty
        )
        #expect(
            HostAppQuotaRouteDetector.classify(
                providerID: "deepseek-proxy",
                baseURL: nil
            ).provider == .thirdParty
        )
    }

    @Test("Codex TOML parser reads documented provider routing keys")
    func codexConfigurationParser() {
        let parsed = HostAppQuotaRouteDetector.parseCodexConfiguration(
            """
            model_provider = "deepseek" # selected provider
            preferred_auth_method = "apikey"

            [model_providers.deepseek]
            name = "DeepSeek"
            base_url = "https://api.deepseek.com/v1"
            env_key = "DEEPSEEK_API_KEY"
            """
        )

        #expect(parsed.modelProvider == "deepseek")
        #expect(parsed.preferredAuthMethod == "apikey")
        #expect(parsed.providers["deepseek"]?.baseURL == "https://api.deepseek.com/v1")
        #expect(parsed.providers["deepseek"]?.environmentKey == "DEEPSEEK_API_KEY")
    }

    @Test("Codex custom provider resolves its billing API and env credential")
    func codexDeepSeekRoute() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(
            at: temporary.appending(path: ".codex"),
            withIntermediateDirectories: true
        )
        try """
        model_provider = "deepseek"
        [model_providers.deepseek]
        base_url = "https://api.deepseek.com/v1"
        env_key = "DEEPSEEK_API_KEY"
        """.write(
            to: temporary.appending(path: ".codex/config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let detector = HostAppQuotaRouteDetector(
            homeDirectory: temporary,
            environment: ["DEEPSEEK_API_KEY": "transient-key"]
        )

        let route = detector.route(for: .codex)

        #expect(route.hostProvider == .codex)
        #expect(route.source?.provider == .deepseek)
        #expect(route.credential == "transient-key")
    }

    @Test("Codex API-key-only auth never falls back to ChatGPT subscription quota")
    func codexAPIKeyOnlyRoute() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codexHome = temporary.appending(path: "custom-codex", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try #"{"OPENAI_API_KEY":"sk-api-only"}"#.write(
            to: codexHome.appending(path: "auth.json"),
            atomically: true,
            encoding: .utf8
        )
        let route = HostAppQuotaRouteDetector(
            homeDirectory: temporary,
            environment: ["CODEX_HOME": codexHome.path]
        ).route(for: .codex)

        #expect(route.isExternal)
        #expect(route.source?.provider == .thirdParty)
        #expect(route.source?.displayName == "OpenAI API")
        #expect(route.credential == "sk-api-only")
    }

    @Test("Malformed Codex relay URL cannot forward its credential to a guessed provider")
    func malformedCodexRelayIsUnmapped() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(
            at: temporary.appending(path: ".codex"),
            withIntermediateDirectories: true
        )
        try """
        model_provider = "deepseek"
        [model_providers.deepseek]
        base_url = "relay.example.com/v1"
        env_key = "RELAY_KEY"
        """.write(
            to: temporary.appending(path: ".codex/config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let route = HostAppQuotaRouteDetector(
            homeDirectory: temporary,
            environment: ["RELAY_KEY": "must-not-forward"]
        ).route(for: .codex)

        #expect(route.source?.provider == .thirdParty)
        #expect(route.baseURL == nil)
    }

    @Test("Malformed default Codex Base URL cannot fall back to ChatGPT quota")
    func malformedDefaultCodexRelayIsExternal() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(
            at: temporary.appending(path: ".codex"),
            withIntermediateDirectories: true
        )
        try #"openai_base_url = "relay.example.com/v1""#.write(
            to: temporary.appending(path: ".codex/config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"tokens":{"access_token":"chatgpt-token"}}"#.write(
            to: temporary.appending(path: ".codex/auth.json"),
            atomically: true,
            encoding: .utf8
        )

        let route = HostAppQuotaRouteDetector(
            homeDirectory: temporary,
            environment: [:]
        ).route(for: .codex)

        #expect(route.isExternal)
        #expect(route.source?.provider == .thirdParty)
        #expect(route.baseURL == nil)
        #expect(route.credential == nil)
    }

    @Test("External Codex routes never inherit the local snapshot polling cadence")
    func externalCodexCadence() {
        #expect(!UsageStore.shouldRefreshCodex(
            enabled: true,
            routeIsExternal: true,
            apiDue: false,
            localSnapshotDue: true
        ))
        #expect(UsageStore.shouldRefreshCodex(
            enabled: true,
            routeIsExternal: true,
            apiDue: true,
            localSnapshotDue: false
        ))
    }

    @Test("Only routed errors invalidate an existing host quota")
    func routedErrorInvalidation() {
        let routed = HostAppQuotaRoutingError(
            sourceName: "DeepSeek API",
            underlyingDescription: "Unavailable"
        )
        #expect(UsageStore.invalidatesCachedQuota(routed))
        #expect(!UsageStore.invalidatesCachedQuota(ExtendedProviderError.notConfigured(.deepseek)))
    }

    @Test("Attributed quota preserves host, source and cache compatibility")
    func attributedQuotaRoundTrip() throws {
        let source = QuotaAttribution(
            provider: .deepseek,
            displayName: "DeepSeek API",
            routeIdentifier: "claude|deepseek|api.deepseek.com"
        )
        let raw = ProviderQuota(
            provider: .deepseek,
            primary: QuotaWindow(usedPercent: 0, windowMinutes: 0, resetsAt: nil),
            secondary: nil,
            planName: "¥12.00",
            capturedAt: Date(timeIntervalSince1970: 123)
        )
        let hosted = raw.attributed(to: .claude, source: source)
        let decoded = try JSONDecoder().decode(
            ProviderQuota.self,
            from: JSONEncoder().encode(hosted)
        )

        #expect(decoded.provider == .claude)
        #expect(decoded.attribution == source)
        #expect(decoded.planName == "¥12.00")
        #expect(
            StatusBarPresentation.tooltipProviderLabel(.claude, quota: decoded)
                .contains("Claude · DeepSeek API")
        )
    }

    @Test("Scoped windows never cross billing routes")
    func routeMatchingProtectsScopedWindows() {
        func quota(routeID: String?) -> ProviderQuota {
            ProviderQuota(
                provider: .claude,
                primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
                secondary: nil,
                planName: nil,
                capturedAt: .now,
                attribution: routeID.map {
                    QuotaAttribution(provider: .deepseek, displayName: "DeepSeek API", routeIdentifier: $0)
                }
            )
        }

        #expect(UsageStore.quotaRoutesMatch(quota(routeID: nil), quota(routeID: nil)))
        #expect(!UsageStore.quotaRoutesMatch(quota(routeID: nil), quota(routeID: "external")))
        #expect(!UsageStore.quotaRoutesMatch(quota(routeID: "one"), quota(routeID: "two")))
    }

    @Test("Quota UI names the billing API without replacing the host header")
    func quotaRowTitleIncludesSource() {
        let source = QuotaAttribution(
            provider: .deepseek,
            displayName: "DeepSeek API",
            routeIdentifier: "route"
        )
        let title = QuotaWindowRow.displayTitle(
            windowMinutes: 0,
            scopeName: nil,
            attribution: source
        )
        #expect(title.contains("DeepSeek API"))
    }

    @Test("OpenCode reads the newest provider and JSONC base URL safely")
    func openCodeRouteParsing() throws {
        let row = OpenCodeUsageService.parseProviderRouteRow(
            Data(#"[1720000000000,"deepseek"]"#.utf8)
        )
        #expect(row?.providerID == "deepseek")

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try """
        {
          // custom route
          "provider": {
            "deepseek": { "options": { "baseURL": "https://relay.example.com/v1" } }
          }
        }
        """.write(
            to: temporary.appending(path: "opencode.jsonc"),
            atomically: true,
            encoding: .utf8
        )
        let baseURL = OpenCodeUsageService.providerBaseURL(
            providerID: "deepseek",
            configurationDirectory: temporary
        )
        #expect(baseURL?.host == "relay.example.com")
    }

    @Test("Generic relay quota configuration must match the routed host")
    func genericRelayConfigurationMatching() throws {
        let configuration = try #require(ThirdPartyConfiguration.parse(
            #"{"adapter":"custom","baseUrl":"https://relay.example.com/v1","apiKey":"secret","endpointPath":"/balance","remainingPath":"data.remaining","currency":"USD"}"#
        ))
        #expect(HostAppQuotaRoutingService.thirdPartyConfiguration(
            configuration,
            matches: URL(string: "https://relay.example.com/anthropic")
        ))
        #expect(!HostAppQuotaRoutingService.thirdPartyConfiguration(
            configuration,
            matches: URL(string: "https://other.example.com/v1")
        ))
        #expect(!HostAppQuotaRoutingService.thirdPartyConfiguration(configuration, matches: nil))
    }

    @Test("Every auxiliary fetcher is actually scheduled")
    func auxiliaryProviderListIncludesPreviouslyOrphanedFetchers() {
        #expect(UsageStore.auxProviders.contains(.zaiTeam))
        #expect(UsageStore.auxProviders.contains(.thirdParty))
    }

    @Test("Quota trends do not connect different billing routes")
    func historyKeepsOnlyLatestBillingRoute() {
        let official = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let external = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 0, windowMinutes: 0, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: Date(timeIntervalSince1970: 2_000),
            attribution: QuotaAttribution(
                provider: .deepseek,
                displayName: "DeepSeek API",
                routeIdentifier: "claude|deepseek|api.deepseek.com"
            )
        )
        let history = QuotaUsageHistory.empty.recording(official).recording(external)
        let visible = history.samples(for: .claude)

        #expect(visible.count == 1)
        #expect(visible.first?.attribution?.provider == .deepseek)
    }
}
