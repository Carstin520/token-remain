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
        guard let apiKey = OpenRouterKeyStore().load() else {
            throw ServiceError.missingKey
        }

        let (data, http) = try await Self.get(Self.creditsURL, apiKey: apiKey)
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ServiceError.keyRejected(http.statusCode)
        default:
            throw ServiceError.requestFailed(http.statusCode)
        }

        // 计划名(Free tier / Pay as you go)取自 /key,尽力而为。
        var planName: String?
        if let (keyData, keyHTTP) = try? await Self.get(Self.keyURL, apiKey: apiKey),
           (200..<300).contains(keyHTTP.statusCode) {
            planName = OpenRouterUsageParser.planName(keyData)
        }

        let quota = try OpenRouterUsageParser.parse(data, planName: planName, now: now)
        Self.logger.info("OpenRouter quota served by credits API")
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
}

/// `/v1/credits` 响应(`data.total_credits` 累计充值、`data.total_usage` 累计
/// 消费,单位美元)→ ProviderQuota。这不是滚动窗口而是终身余额,
/// windowMinutes 用 0 哨兵表示"累计",无重置时间。
enum OpenRouterUsageParser {
    static func parse(_ data: Data, planName: String? = nil, now: Date = .now) throws -> ProviderQuota {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let usage = number(payload["total_usage"]) else {
            throw OpenRouterUsageService.ServiceError.invalidResponse
        }
        let credits = max(0, number(payload["total_credits"]) ?? 0)
        guard credits > 0 else {
            throw OpenRouterUsageService.ServiceError.noCredits
        }
        return ProviderQuota(
            provider: .openrouter,
            primary: QuotaWindow(
                usedPercent: min(100, max(0, usage / credits * 100)),
                windowMinutes: 0,
                resetsAt: nil
            ),
            secondary: nil,
            planName: planName,
            capturedAt: now
        )
    }

    static func planName(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let isFree = payload["is_free_tier"] as? Bool else {
            return nil
        }
        return isFree ? "Free Tier" : "Pay As You Go"
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
