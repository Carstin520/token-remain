import Foundation
import OSLog

/// Z.ai(智谱 GLM Coding Plan)额度直查。参考 OpenUsage(MIT)的 Z.ai
/// provider。Z.ai 没有本地工具凭证可复用,是唯一需要用户手动提供
/// API Key 的 provider:优先读环境变量与 CLI 惯用配置文件,最后读
/// 用户在「数据源」页粘贴、存入钥匙串的 Key。
struct ZAIUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case missingKey
        case keyRejected(Int)
        case noCodingPlan
        case requestFailed(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "未配置 Z.ai API Key；在 Dashboard「数据源」页粘贴一次即可接入"
            case .keyRejected(let status):
                return "Z.ai 拒绝了当前 API Key（HTTP \(status)）；请在「数据源」页更新"
            case .noCodingPlan:
                return "该 Z.ai 账户没有 GLM Coding Plan 订阅"
            case .requestFailed(let status):
                return "Z.ai 用量接口请求失败（HTTP \(status)）"
            case .invalidResponse:
                return "Z.ai 用量接口返回了无法识别的内容"
            }
        }
    }

    private static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    private static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "ZAIUsage")

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let apiKey = ZAIKeyStore().load() else {
            throw ServiceError.missingKey
        }

        let (data, http) = try await Self.get(Self.quotaURL, apiKey: apiKey)
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ServiceError.keyRejected(http.statusCode)
        default:
            throw ServiceError.requestFailed(http.statusCode)
        }
        if ZAIUsageParser.isNoCodingPlan(data) {
            throw ServiceError.noCodingPlan
        }

        // 计划名尽力而为,失败不影响额度本身。
        var planName: String?
        if let (subData, subHTTP) = try? await Self.get(Self.subscriptionURL, apiKey: apiKey),
           (200..<300).contains(subHTTP.statusCode) {
            planName = ZAIUsageParser.planName(subData)
        }

        let quota = try ZAIUsageParser.parse(data, planName: planName, now: now)
        Self.logger.info("Z.ai quota served by monitor API")
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

/// `/api/monitor/usage/quota/limit` 响应 → ProviderQuota。`data.limits` 数组里
/// `TOKENS_LIMIT` 条目的窗口由 `(unit, number)` 编码(unit 3=小时、4=天、
/// 6=周、5=月):亚天级窗口作 5 小时式会话主窗口,多天窗口作周级副窗口;
/// `percentage` 为已用百分比,`nextResetTime` 为 epoch 毫秒。
enum ZAIUsageParser {
    static func parse(_ data: Data, planName: String? = nil, now: Date = .now) throws -> ProviderQuota {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }
        let container = (root["data"] as? [String: Any]) ?? root
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }

        var session: QuotaWindow?
        var weekly: QuotaWindow?
        for entry in limits {
            let type = (entry["type"] as? String) ?? (entry["name"] as? String)
            guard type == "TOKENS_LIMIT",
                  let minutes = windowMinutes(entry),
                  let window = window(entry, minutes: minutes) else {
                continue
            }
            if minutes < 24 * 60 {
                if session == nil { session = window }
            } else if weekly == nil {
                weekly = window
            }
        }

        guard let primary = session ?? weekly else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }
        return ProviderQuota(
            provider: .zai,
            primary: primary,
            secondary: session == nil ? nil : weekly,
            planName: planName,
            capturedAt: now
        )
    }

    /// 有效 Key 但没有 Coding Plan 时,Z.ai 返回 2xx 的
    /// `{"success": false, "msg": "…coding plan…"}`。
    static func isNoCodingPlan(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["success"] as? Bool == false else {
            return false
        }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    /// `/api/biz/subscription/list` 首个条目的 `productName`,如 "GLM Coding Max"。
    static func planName(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]],
              let name = (list.first?["productName"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private static func windowMinutes(_ entry: [String: Any]) -> Int? {
        guard let unit = number(entry["unit"]), let count = number(entry["number"]), count > 0 else {
            return nil
        }
        let unitMinutes: Double
        switch unit {
        case 3: unitMinutes = 60
        case 4: unitMinutes = 24 * 60
        case 6: unitMinutes = 7 * 24 * 60
        case 5: unitMinutes = 30 * 24 * 60
        default: return nil
        }
        let minutes = unitMinutes * count
        guard minutes >= 1, minutes < Double(Int.max) else { return nil }
        return Int(minutes)
    }

    private static func window(_ entry: [String: Any], minutes: Int) -> QuotaWindow? {
        guard let percent = number(entry["percentage"]) else { return nil }
        let resetsAt = number(entry["nextResetTime"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return QuotaWindow(
            usedPercent: min(100, max(0, percent)),
            windowMinutes: minutes,
            resetsAt: resetsAt
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// Z.ai API Key 的读取与保存。读取顺序:环境变量 `ZAI_API_KEY` →
/// `~/.config/zai/key.json`(`apiKey`/`api_key`/`key` 字段或裸字符串)→
/// 用户在「数据源」页保存到钥匙串的 Key。保存/清除只操作钥匙串,
/// 绝不写用户的配置文件。
struct ZAIKeyStore {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    private var keychain: KeychainSecretStore {
        KeychainSecretStore(service: "com.jamesli.usagedock.zai", account: "api-key")
    }

    func load() -> String? {
        if let key = normalized(environment["ZAI_API_KEY"]) {
            return key
        }
        let configFile = homeDirectory.appending(path: ".config/zai/key.json")
        if let text = try? String(contentsOf: configFile, encoding: .utf8),
           let key = Self.key(fromConfigText: text) {
            return key
        }
        return normalized((try? keychain.read()) ?? nil)
    }

    /// 钥匙串里是否存了 Key(区别于环境变量/配置文件来源,供 UI 显示状态)。
    func hasStoredKey() -> Bool {
        normalized((try? keychain.read()) ?? nil) != nil
    }

    func save(_ key: String) throws {
        try keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func clear() throws {
        try keychain.delete()
    }

    static func key(fromConfigText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for field in ["apiKey", "api_key", "key"] {
                if let key = (object[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !key.isEmpty {
                    return key
                }
            }
            return nil
        }
        // 非 JSON 时按裸 Key 处理(去掉可能的引号)。
        let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return bare.isEmpty ? nil : bare
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
