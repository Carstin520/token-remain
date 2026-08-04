import Foundation

// MARK: - GLM Team (single China-region account)

struct ZAITeamConfiguration: Equatable, Sendable {
    let apiKey: String
    let organizationID: String
    let projectID: String

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedValue: String? = ProviderSecretStore(provider: .zaiTeam).load()
    ) -> Self? {
        func clean(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        if let apiKey = clean(environment["ZAI_TEAM_API_KEY"] ?? environment["BIGMODEL_TEAM_API_KEY"]),
           let organization = clean(environment["ZAI_TEAM_ORGANIZATION_ID"]),
           let project = clean(environment["ZAI_TEAM_PROJECT_ID"]) {
            return Self(apiKey: apiKey, organizationID: organization, projectID: project)
        }
        return storedValue.flatMap(parse)
    }

    static func parse(_ raw: String) -> Self? {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        func field(_ names: String...) -> String? {
            for name in names {
                if let value = (object[name] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        guard let apiKey = field("apiKey", "api_key", "key"),
              let organization = field("organization", "organizationId", "organization_id"),
              let project = field("project", "projectId", "project_id") else {
            return nil
        }
        return Self(apiKey: apiKey, organizationID: organization, projectID: project)
    }
}

struct ZAITeamUsageService {
    private static let quotaURL = URL(
        string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit?type=2"
    )!

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let configuration = ZAITeamConfiguration.load() else {
            throw ExtendedProviderError.invalidSecret(
                .zaiTeam,
                detail: L10n.text("service.zai_team.config_incomplete")
            )
        }
        let data = try await ExtendedHTTP.request(
            .zaiTeam,
            url: Self.quotaURL,
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "bigmodel-organization": configuration.organizationID,
                "bigmodel-project": configuration.projectID,
                "Accept": "application/json"
            ]
        )
        return try Self.parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        let personal = try ZAIUsageParser.parse(data, planName: "Team", now: now)
        return ProviderQuota(
            provider: .zaiTeam,
            primary: personal.primary,
            secondary: personal.secondary,
            planName: personal.planName ?? "Team",
            capturedAt: now,
            extraUsage: personal.extraUsage,
            spend: personal.spend,
            accountBalance: personal.accountBalance,
            scopedWindows: personal.scopedWindows,
            remainingBalance: personal.remainingBalance
        )
    }
}

// MARK: - New API / compatible relay (single account)

struct ThirdPartyConfiguration: Equatable, Sendable {
    enum Adapter: String, Sendable {
        case newAPIAccount = "newapi-account"
        case newAPIToken = "newapi-token"
        case custom
    }

    enum AuthMode: String, Sendable {
        case bearer
        case xAPIKey = "x-api-key"
    }

    let adapter: Adapter
    let baseURL: URL
    let credential: String
    let userID: String?
    let endpointPath: String?
    let authMode: AuthMode
    let remainingPath: String?
    let usedPath: String?
    let totalPath: String?
    let currency: String
    let divisor: Double

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedValue: String? = ProviderSecretStore(provider: .thirdParty).load()
    ) -> Self? {
        if let raw = storedValue, let parsed = parse(raw) { return parsed }
        let base = environment["TOKEN_MONITOR_NEWAPI_BASE_URL"] ?? ""
        if let token = environment["TOKEN_MONITOR_NEWAPI_ACCESS_TOKEN"], !token.isEmpty {
            return parseObject([
                "adapter": "newapi-account", "baseUrl": base, "accessToken": token,
                "userId": environment["TOKEN_MONITOR_NEWAPI_USER_ID"] ?? ""
            ])
        }
        if let key = environment["TOKEN_MONITOR_NEWAPI_API_KEY"], !key.isEmpty {
            return parseObject([
                "adapter": "newapi-token", "baseUrl": base, "apiKey": key
            ])
        }
        return nil
    }

    static func parse(_ raw: String) -> Self? {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parseObject(object)
    }

    private static func parseObject(_ object: [String: Any]) -> Self? {
        func text(_ key: String) -> String {
            ((object[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let adapter = Adapter(rawValue: text("adapter")),
              let baseURL = normalizedBaseURL(text("baseUrl"), stripV1: adapter != .custom) else {
            return nil
        }
        let credential = adapter == .newAPIAccount ? text("accessToken") : text("apiKey")
        guard !credential.isEmpty else { return nil }

        let endpoint = adapter == .custom
            ? normalizedEndpointPath(text("endpointPath").isEmpty ? "/user/balance" : text("endpointPath"))
            : nil
        let remaining = adapter == .custom ? normalizedJSONPath(text("remainingPath")) : nil
        let used = text("usedPath").isEmpty ? nil : normalizedJSONPath(text("usedPath"))
        let total = text("totalPath").isEmpty ? nil : normalizedJSONPath(text("totalPath"))
        let authMode = AuthMode(rawValue: text("authMode").isEmpty ? "bearer" : text("authMode"))
        let currency = (text("currency").isEmpty ? "USD" : text("currency")).uppercased()
        let divisor = number(object["divisor"]) ?? 1
        if adapter == .custom {
            guard endpoint != nil, remaining != nil, authMode != nil,
                  (used == nil) == text("usedPath").isEmpty,
                  (total == nil) == text("totalPath").isEmpty,
                  currency.range(of: #"^[A-Z]{3,8}$"#, options: .regularExpression) != nil,
                  divisor > 0, divisor <= 1e15 else {
                return nil
            }
        }

        return Self(
            adapter: adapter,
            baseURL: baseURL,
            credential: credential,
            userID: text("userId").isEmpty ? nil : text("userId"),
            endpointPath: endpoint,
            authMode: authMode ?? .bearer,
            remainingPath: remaining,
            usedPath: used,
            totalPath: total,
            currency: currency,
            divisor: divisor
        )
    }

    static func normalizedBaseURL(_ raw: String, stripV1: Bool = true) -> URL? {
        guard var components = URLComponents(string: raw),
              components.scheme == "https" || components.scheme == "http",
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        if components.scheme == "http",
           !["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) {
            // The JSON-only setup flow has no durable warning/confirmation UI;
            // fail closed instead of sending a bearer credential in cleartext.
            return nil
        }
        var path = components.path.replacingOccurrences(
            of: #"/+$"#, with: "", options: .regularExpression
        )
        if stripV1, path.lowercased().hasSuffix("/v1") {
            path.removeLast(3)
        }
        components.path = path
        return components.url
    }

    static func normalizedEndpointPath(_ raw: String) -> String? {
        guard raw.count <= 256, raw.hasPrefix("/"), !raw.hasPrefix("//"),
              !raw.contains("\\"), !raw.contains("?"), !raw.contains("#"),
              let decoded = raw.removingPercentEncoding,
              !decoded.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        return raw
    }

    static func normalizedJSONPath(_ raw: String) -> String? {
        guard (1...160).contains(raw.count) else { return nil }
        let blocked = Set(["__proto__", "prototype", "constructor"])
        let segments = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count <= 12,
              segments.allSatisfy({ segment in
                  !blocked.contains(segment)
                      && segment.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
              }) else {
            return nil
        }
        return segments.joined(separator: ".")
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

struct ThirdPartyUsageService {
    static let defaultQuotaPerUnit: Double = 500_000

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let configuration = ThirdPartyConfiguration.load() else {
            throw ExtendedProviderError.invalidSecret(
                .thirdParty,
                detail: L10n.text("service.third_party.config_incomplete")
            )
        }
        let quotaRequest = request(for: configuration)
        async let quotaAttempt = ExtendedHTTP.request(
            .thirdParty,
            url: endpoint(configuration.baseURL, path: quotaRequest.path),
            headers: quotaRequest.headers,
            followRedirects: false
        )
        async let statusAttempt = statusData(for: configuration)
        let quotaData = try await quotaAttempt
        let statusData = try await statusAttempt
        return try Self.parse(
            quotaData: quotaData,
            statusData: statusData,
            configuration: configuration,
            now: now
        )
    }

    static func parse(
        quotaData: Data,
        statusData: Data?,
        configuration: ThirdPartyConfiguration,
        now: Date = .now
    ) throws -> ProviderQuota {
        guard let root = ExtendedHTTP.json(quotaData) else {
            throw ExtendedProviderError.invalidResponse(.thirdParty)
        }
        let unit = statusData.flatMap(ExtendedHTTP.json)
            .flatMap(responseData)
            .flatMap { number($0["quota_per_unit"]) }
            .flatMap { $0 > 0 ? $0 : nil }
            ?? defaultQuotaPerUnit

        let result: BalanceResult?
        switch configuration.adapter {
        case .newAPIAccount:
            guard let data = responseData(root) else {
                throw ExtendedProviderError.invalidResponse(.thirdParty)
            }
            let rawRemaining = number(data["quota"])
            let unlimited = data["unlimited_quota"] as? Bool == true || rawRemaining == -1
            result = balanceResult(
                remaining: unlimited ? nil : rawRemaining.map { max(0, $0) / unit },
                used: number(data["used_quota"]).map { max(0, $0) / unit },
                total: nil,
                currency: "USD",
                unlimited: unlimited,
                resetsAt: nil
            )
        case .newAPIToken:
            guard let data = responseData(root) else {
                throw ExtendedProviderError.invalidResponse(.thirdParty)
            }
            result = balanceResult(
                remaining: number(data["total_available"]).map { max(0, $0) / unit },
                used: number(data["total_used"]).map { max(0, $0) / unit },
                total: nil,
                currency: "USD",
                unlimited: data["unlimited_quota"] as? Bool == true,
                resetsAt: number(data["expires_at"]).flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
                }
            )
        case .custom:
            if root["success"] as? Bool == false || root["code"] as? Bool == false {
                throw ExtendedProviderError.invalidResponse(.thirdParty)
            }
            let remaining = value(at: configuration.remainingPath, in: root)
                .flatMap(number).map { $0 / configuration.divisor }
            let used = value(at: configuration.usedPath, in: root)
                .flatMap(number).map { $0 / configuration.divisor }
            let total = value(at: configuration.totalPath, in: root)
                .flatMap(number).map { $0 / configuration.divisor }
            result = balanceResult(
                remaining: remaining,
                used: used,
                total: total,
                currency: configuration.currency,
                unlimited: false,
                resetsAt: nil
            )
        }
        guard let result else { throw ExtendedProviderError.invalidResponse(.thirdParty) }

        let planName: String = switch configuration.adapter {
        case .newAPIAccount: result.unlimited ? "Account · Unlimited" : "Account"
        case .newAPIToken: result.unlimited ? "API Key · Unlimited" : "API Key"
        case .custom: "Custom"
        }

        return ProviderQuota(
            provider: .thirdParty,
            primary: result.window,
            secondary: nil,
            planName: planName,
            capturedAt: now,
            spend: (configuration.adapter != .custom || configuration.currency == "USD")
                ? result.used.map {
                    ProviderSpend(todayUSD: nil, weekUSD: nil, monthUSD: nil, allTimeUSD: $0)
                }
                : nil,
            remainingBalance: result.window.remainingBalance
        )
    }

    private struct BalanceResult {
        let window: QuotaWindow
        let used: Double?
        let unlimited: Bool
    }

    private static func balanceResult(
        remaining: Double?,
        used: Double?,
        total explicitTotal: Double?,
        currency: String,
        unlimited: Bool,
        resetsAt: Date?
    ) -> BalanceResult? {
        if unlimited {
            return BalanceResult(
                window: QuotaWindow(usedPercent: 0, windowMinutes: 0, resetsAt: resetsAt),
                used: used,
                unlimited: true
            )
        }
        guard let remaining, remaining.isFinite, remaining >= 0 else { return nil }
        let total = explicitTotal ?? used.map { remaining + max(0, $0) }
        if let total, total < remaining { return nil }
        let meterUsed = used ?? total.map { max(0, $0 - remaining) }
        let percent = if let total, let meterUsed {
            total > 0 ? min(100.0, max(0.0, meterUsed / total * 100)) : 100.0
        } else {
            remaining > 0 ? 0.0 : 100.0
        }
        return BalanceResult(
            window: QuotaWindow(
                usedPercent: percent,
                windowMinutes: 0,
                resetsAt: resetsAt,
                remainingBalance: QuotaBalance(amount: remaining, currencyCode: currency)
            ),
            used: used,
            unlimited: false
        )
    }

    private static func responseData(_ root: [String: Any]) -> [String: Any]? {
        if root["success"] as? Bool == false || root["code"] as? Bool == false { return nil }
        return root["data"] as? [String: Any]
    }

    private static func value(at path: String?, in root: Any) -> Any? {
        guard let path else { return nil }
        var current: Any = root
        for segment in path.split(separator: ".").map(String.init) {
            guard let object = current as? [String: Any], let next = object[segment] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private func request(
        for configuration: ThirdPartyConfiguration
    ) -> (path: String, headers: [String: String]) {
        switch configuration.adapter {
        case .newAPIAccount:
            var headers = ["Authorization": "Bearer \(configuration.credential)", "Accept": "application/json"]
            if let userID = configuration.userID { headers["New-Api-User"] = userID }
            return ("/api/user/self", headers)
        case .newAPIToken:
            return (
                "/api/usage/token/",
                ["Authorization": "Bearer \(configuration.credential)", "Accept": "application/json"]
            )
        case .custom:
            let auth = configuration.authMode == .xAPIKey
                ? ["x-api-key": configuration.credential]
                : ["Authorization": "Bearer \(configuration.credential)"]
            return (configuration.endpointPath ?? "/user/balance", auth.merging(["Accept": "application/json"]) { left, _ in left })
        }
    }

    private func statusData(for configuration: ThirdPartyConfiguration) async throws -> Data? {
        guard configuration.adapter != .custom else { return nil }
        return try await ExtendedHTTP.request(
            .thirdParty,
            url: endpoint(configuration.baseURL, path: "/api/status"),
            headers: ["Accept": "application/json"],
            followRedirects: false
        )
    }

    private func endpoint(_ baseURL: URL, path: String) -> URL {
        // Both values were normalized before they reached the service. Joining
        // their encoded forms preserves a legitimate `%2F` in a custom path;
        // assigning through URLComponents.path would encode `%` a second time.
        return URL(string: baseURL.absoluteString + path)!
    }
}
