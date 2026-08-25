import Foundation
import OSLog

/// OpenRouter 预充积分直查。参考 OpenUsage(MIT)的 OpenRouter provider。
/// 与 Z.ai 同类:没有本地工具凭证可复用,Key 来自环境变量 / 配置文件 /
/// 用户在「数据源」页粘贴的钥匙串条目。
struct OpenRouterUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case missingKey
        case keyRejected(Int)
        case requestFailed(Int)
        case invalidResponse
        case noCredits

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return L10n.format("service.common.api_key_missing", "OpenRouter")
            case .keyRejected(let status):
                return L10n.format("service.common.api_key_rejected", "OpenRouter", status)
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed", "OpenRouter", status)
            case .invalidResponse:
                return L10n.format("service.common.invalid_response", "OpenRouter")
            case .noCredits:
                return L10n.text("service.openrouter.no_credits")
            }
        }
    }

    private static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    private static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "OpenRouterUsage")

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(apiKey: nil, now: now)
    }

    func fetch(apiKey routedKey: String?, now: Date = .now) async throws -> ProviderQuota {
        let cleaned = routedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = (cleaned?.isEmpty == false ? cleaned : nil) ?? OpenRouterKeyStore().load() else {
            throw ServiceError.missingKey
        }

        // The two endpoints expose complementary data and either can remain
        // useful while the other is temporarily unavailable. Fetch both at
        // once so a key-level cap never waits on the account credits request.
        async let creditsAttempt = Self.getResult(Self.creditsURL, apiKey: apiKey)
        async let keyAttempt = Self.getResult(Self.keyURL, apiKey: apiKey)
        let (creditsResult, keyResult) = await (creditsAttempt, keyAttempt)
        let creditsResponse = try? creditsResult.get()
        let keyResponse = try? keyResult.get()

        let creditsData = creditsResponse.flatMap {
            (200..<300).contains($0.1.statusCode) ? $0.0 : nil
        }
        let keyData = keyResponse.flatMap {
            (200..<300).contains($0.1.statusCode) ? $0.0 : nil
        }
        guard creditsData != nil || keyData != nil else {
            let statuses = [creditsResponse?.1.statusCode, keyResponse?.1.statusCode].compactMap { $0 }
            if let rejected = statuses.first(where: { $0 == 401 || $0 == 403 }),
               statuses.allSatisfy({ $0 == 401 || $0 == 403 }) {
                throw ServiceError.keyRejected(rejected)
            }
            if statuses.isEmpty {
                if case .failure(let error) = creditsResult { throw error }
                if case .failure(let error) = keyResult { throw error }
            }
            throw ServiceError.requestFailed(statuses.first ?? 0)
        }

        let quota = try OpenRouterUsageParser.parse(
            creditsData: creditsData,
            keyData: keyData,
            now: now
        )
        Self.logger.info("OpenRouter quota served by key and credits APIs")
        return quota
    }

    private static func get(_ url: URL, apiKey: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        return (data, http)
    }

    private static func getResult(
        _ url: URL,
        apiKey: String
    ) async -> Result<(Data, HTTPURLResponse), Error> {
        do { return .success(try await get(url, apiKey: apiKey)) }
        catch { return .failure(error) }
    }
}

/// `/v1/credits` 响应(`data.total_credits` 累计充值、`data.total_usage` 累计
/// 消费,单位美元)→ ProviderQuota。这不是滚动窗口而是终身余额,
/// windowMinutes 用 0 哨兵表示"累计",无重置时间。
enum OpenRouterUsageParser {
    /// 积分池在与 key 限额同为 0 分钟(累计)时的 scoped 身份;
    /// scopeID 满足手机同步的 `[a-z0-9_-]{1,32}` 约束。
    static let creditsScopeID = "openrouter_credits"
    static let creditsDisplayName = "Credits"

    /// Backward-compatible entry point used by cached fixtures and focused
    /// parser tests that only contain the credits response.
    static func parse(_ data: Data, planName: String? = nil, now: Date = .now) throws -> ProviderQuota {
        try parse(creditsData: data, keyData: nil, planNameOverride: planName, now: now)
    }

    static func parse(
        creditsData: Data?,
        keyData: Data?,
        planNameOverride: String? = nil,
        now: Date = .now
    ) throws -> ProviderQuota {
        let creditsPayload = creditsData.flatMap(payload)
        let keyPayload = keyData.flatMap(payload)
        let keyWindow = keyPayload.flatMap(limitWindow)
        let creditsWindow = creditsPayload.flatMap(creditsWindow)
        guard let primary = keyWindow ?? creditsWindow else {
            throw OpenRouterUsageService.ServiceError.invalidResponse
        }

        let spend = keyPayload.map(spendSummary).flatMap { $0.hasValues ? $0 : nil }
        let primaryBalance = primary.remainingBalance
        let canPublishCreditsWindow = keyWindow.map {
            $0.windowMinutes != creditsWindow?.windowMinutes
        } ?? false
        // key 限额无周期时它与积分池同为 0 分钟:手机同步拒收同 provider 两个
        // 同时长的账户级窗口,所以积分池不能进 secondary。以前这里降级成纯
        // accountBalance,把"已用 xx%"的百分比维度整个丢掉;现在改走 scoped
        // 出口——同步查重只看 primary/secondary,scoped 明确允许与 primary
        // 同时长,所以百分比和剩余美元能同时保住,也不再需要 accountBalance
        // 兜底(留着会和 scoped 行重复显示同一笔余额)。
        let scopedCredits: [ScopedQuotaWindow]? =
            keyWindow != nil && !canPublishCreditsWindow
                ? creditsWindow.map {
                    [
                        ScopedQuotaWindow(
                            scopeID: creditsScopeID,
                            displayName: creditsDisplayName,
                            window: $0,
                            observedAt: now
                        )
                    ]
                }
                : nil
        return ProviderQuota(
            provider: .openrouter,
            primary: primary,
            secondary: canPublishCreditsWindow ? creditsWindow : nil,
            planName: planNameOverride ?? keyPayload.flatMap(planName),
            capturedAt: now,
            spend: spend,
            scopedWindows: scopedCredits,
            remainingBalance: primaryBalance
        )
    }

    static func planName(_ data: Data) -> String? {
        payload(data).flatMap(planName)
    }

    private static func payload(_ data: Data) -> [String: Any]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return (root["data"] as? [String: Any]) ?? root
    }

    private static func planName(_ payload: [String: Any]) -> String? {
        if payload["is_management_key"] as? Bool == true { return "Management" }
        guard let isFree = payload["is_free_tier"] as? Bool else { return nil }
        return isFree ? "Free Tier" : "Pay As You Go"
    }

    private static func limitWindow(_ payload: [String: Any]) -> QuotaWindow? {
        guard let limit = number(payload["limit"]), limit.isFinite, limit > 0 else { return nil }
        let rawUsed = number(payload["usage"])
        let rawRemaining = number(payload["limit_remaining"])
        guard rawUsed != nil || rawRemaining != nil else { return nil }
        let used = max(0, rawUsed ?? (limit - (rawRemaining ?? limit)))
        let remaining = max(0, rawRemaining ?? (limit - used))
        let reset = (payload["limit_reset"] as? String)?.lowercased()
        let minutes = switch reset {
        case "daily": 1_440
        case "weekly": 10_080
        case "monthly": 43_200
        default: 0
        }
        return QuotaWindow(
            usedPercent: min(100, max(0, used / limit * 100)),
            windowMinutes: minutes,
            resetsAt: nil,
            remainingBalance: QuotaBalance(amount: remaining, currencyCode: "USD")
        )
    }

    private static func creditsWindow(_ payload: [String: Any]) -> QuotaWindow? {
        guard let rawCredits = number(payload["total_credits"]), rawCredits.isFinite, rawCredits >= 0,
              let rawUsage = number(payload["total_usage"]), rawUsage.isFinite, rawUsage >= 0 else {
            return nil
        }
        let credits = max(0, rawCredits)
        let usage = max(0, rawUsage)
        let remaining = max(0, credits - usage)
        return QuotaWindow(
            usedPercent: credits > 0 ? min(100, max(0, usage / credits * 100)) : 100,
            windowMinutes: 0,
            resetsAt: nil,
            remainingBalance: QuotaBalance(amount: remaining, currencyCode: "USD")
        )
    }

    private static func spendSummary(_ payload: [String: Any]) -> ProviderSpend {
        func amount(_ key: String) -> Double? {
            guard let value = number(payload[key]), value.isFinite else { return nil }
            return max(0, value)
        }
        return ProviderSpend(
            todayUSD: amount("usage_daily"),
            weekUSD: amount("usage_weekly"),
            monthUSD: amount("usage_monthly"),
            allTimeUSD: amount("usage")
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// OpenRouter API Key 读取与保存,结构与 `ZAIKeyStore` 一致:
/// 环境变量 `OPENROUTER_API_KEY` → `~/.config/openrouter/key.json` →
/// 用户存入钥匙串的 Key。保存/清除只操作钥匙串。
struct OpenRouterKeyStore {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    private var keychain: KeychainSecretStore {
        KeychainSecretStore(service: "com.jamesli.usagedock.openrouter", account: "api-key")
    }

    func load() -> String? {
        if let key = normalized(environment["OPENROUTER_API_KEY"]) {
            return key
        }
        let configFile = homeDirectory.appending(path: ".config/openrouter/key.json")
        if let text = try? String(contentsOf: configFile, encoding: .utf8),
           let key = ZAIKeyStore.key(fromConfigText: text) {
            return key
        }
        return normalized((try? keychain.read()) ?? nil)
    }

    func hasStoredKey() -> Bool {
        normalized((try? keychain.read()) ?? nil) != nil
    }

    func save(_ key: String) throws {
        try keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
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
