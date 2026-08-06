import Foundation
import OSLog

/// Z.ai(智谱 GLM Coding Plan)额度直查。参考 OpenUsage(MIT)的 Z.ai
/// provider。Z.ai 没有本地工具凭证可复用，需要用户手动提供
/// API Key：优先读环境变量与 CLI 惯用配置文件，最后读
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
                return L10n.format("service.common.api_key_missing", "Z.ai")
            case .keyRejected(let status):
                return L10n.format("service.common.api_key_rejected", "Z.ai", status)
            case .noCodingPlan:
                return L10n.text("service.zai.no_coding_plan")
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed", "Z.ai", status)
            case .invalidResponse:
                return L10n.format("service.common.invalid_response", "Z.ai")
            }
        }
    }

    private static let quotaPath = "/api/monitor/usage/quota/limit"
    private static let subscriptionPath = "/api/biz/subscription/list"
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "ZAIUsage")

    var region: ZAIAPIRegion = ZAIRegionStore().load()

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(apiKey: nil, region: nil, now: now)
    }

    func fetch(
        apiKey routedKey: String?,
        region routedRegion: ZAIAPIRegion?,
        now: Date = .now
    ) async throws -> ProviderQuota {
        let cleaned = routedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = (cleaned?.isEmpty == false ? cleaned : nil) ?? ZAIKeyStore().load() else {
            throw ServiceError.missingKey
        }

        // Region is an explicit privacy boundary: never retry the credential
        // against the other jurisdiction's host without a user action.
        return try await fetch(apiKey: apiKey, region: routedRegion ?? region, now: now)
    }

    private func fetch(
        apiKey: String,
        region: ZAIAPIRegion,
        now: Date
    ) async throws -> ProviderQuota {
        let quotaURL = region.baseURL.appending(path: Self.quotaPath)
        let subscriptionURL = region.baseURL.appending(path: Self.subscriptionPath)
        let (data, http) = try await Self.get(quotaURL, apiKey: apiKey)
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
        var subscriptionResetAt: Date?
        if let (subData, subHTTP) = try? await Self.get(subscriptionURL, apiKey: apiKey),
           (200..<300).contains(subHTTP.statusCode) {
            planName = ZAIUsageParser.planName(subData)
            subscriptionResetAt = ZAIUsageParser.subscriptionResetAt(subData)
        }

        let quota = try ZAIUsageParser.parse(
            data,
            planName: planName,
            subscriptionResetAt: subscriptionResetAt,
            now: now
        )
        Self.logger.info("Z.ai quota served by monitor API in \(region.rawValue, privacy: .public) region")
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
/// `TOKENS_LIMIT` 条目的窗口由 `(unit, number)` 编码(unit 5=分钟、3=小时、
/// 1/4=天、6=周):亚天级窗口作 5 小时式会话主窗口,多天窗口作周级副窗口;
/// `percentage` 为已用百分比,`nextResetTime` 为 epoch 毫秒。
enum ZAIUsageParser {
    static func parse(
        _ data: Data,
        planName: String? = nil,
        subscriptionResetAt: Date? = nil,
        now: Date = .now
    ) throws -> ProviderQuota {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }
        let container = (root["data"] as? [String: Any]) ?? root
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }

        var tokenWindows: [QuotaWindow] = []
        var scopedWindows: [ScopedQuotaWindow] = []
        for entry in limits {
            let type = (
                (entry["type"] as? String)
                    ?? (entry["limit_type"] as? String)
                    ?? (entry["name"] as? String)
                    ?? ""
            )
                .uppercased()
            if type == "TOKENS_LIMIT",
               let minutes = windowMinutes(entry),
               let quotaWindow = window(entry, minutes: minutes) {
                tokenWindows.append(quotaWindow)
            } else if type == "TIME_LIMIT",
                      let quotaWindow = window(
                          entry,
                          minutes: 43_200,
                          fallbackResetAt: subscriptionResetAt
                      ) {
                scopedWindows.append(
                    ScopedQuotaWindow(
                        scopeID: "zai_mcp_monthly",
                        displayName: "MCP",
                        window: quotaWindow
                    )
                )
            }
        }

        tokenWindows.sort { $0.windowMinutes < $1.windowMinutes }
        var seenWindowMinutes = Set<Int>()
        tokenWindows = tokenWindows.filter { seenWindowMinutes.insert($0.windowMinutes).inserted }
        let session: QuotaWindow?
        let weekly: QuotaWindow?
        if tokenWindows.count >= 2 {
            session = tokenWindows.first
            weekly = tokenWindows.last
        } else if let only = tokenWindows.first, only.windowMinutes <= 6 * 60 {
            session = only
            weekly = nil
        } else {
            session = nil
            weekly = tokenWindows.first
        }

        guard let primary = session ?? weekly ?? scopedWindows.first?.window else {
            throw ZAIUsageService.ServiceError.invalidResponse
        }
        return ProviderQuota(
            provider: .zai,
            primary: primary,
            secondary: session == nil ? nil : weekly,
            planName: planName,
            capturedAt: now,
            scopedWindows: scopedWindows.isEmpty ? nil : scopedWindows
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

    static func subscriptionResetAt(_ data: Data) -> Date? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]],
              let first = list.first else {
            return nil
        }
        let value = first["next_renew_time"] ?? first["nextRenewTime"]
        if let timestamp = number(value) {
            return Date(timeIntervalSince1970: timestamp < 20_000_000_000 ? timestamp : timestamp / 1000)
        }
        guard let raw = value as? String else { return nil }
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: normalized)
            ?? ISO8601DateFormatter().date(from: normalized)
            ?? ISO8601DateFormatter().date(from: "\(normalized)Z")
    }

    private static func windowMinutes(_ entry: [String: Any]) -> Int? {
        guard let unit = number(entry["unit"]), let count = number(entry["number"]), count > 0 else {
            return nil
        }
        let unitMinutes: Double
        switch unit {
        case 1, 4: unitMinutes = 24 * 60
        case 3: unitMinutes = 60
        case 5: unitMinutes = 1
        case 6: unitMinutes = 7 * 24 * 60
        default: return nil
        }
        let minutes = unitMinutes * count
        guard minutes >= 1, minutes < Double(Int.max) else { return nil }
        return Int(minutes)
    }

    private static func window(
        _ entry: [String: Any],
        minutes: Int,
        fallbackResetAt: Date? = nil
    ) -> QuotaWindow? {
        let percent: Double?
        if let total = number(entry["usage"]), total > 0 {
            let remaining = number(entry["remaining"])
            let current = number(entry["currentValue"] ?? entry["current_value"])
            if remaining != nil || current != nil {
                let usedFromRemaining = remaining.map { total - $0 }
                let used = max(0, min(total, max(usedFromRemaining ?? 0, current ?? 0)))
                percent = used / total * 100
            } else {
                percent = number(entry["percentage"] ?? entry["usedPercent"] ?? entry["used_percent"])
            }
        } else {
            percent = number(entry["percentage"] ?? entry["usedPercent"] ?? entry["used_percent"])
        }
        guard let percent else { return nil }
        let resetsAt = number(entry["nextResetTime"] ?? entry["next_reset_time"]).map {
            Date(timeIntervalSince1970: $0 < 20_000_000_000 ? $0 : $0 / 1000)
        } ?? fallbackResetAt
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

enum ZAIAPIRegion: String, CaseIterable, Sendable {
    case global
    case china

    var baseURL: URL {
        switch self {
        case .global: URL(string: "https://api.z.ai")!
        case .china: URL(string: "https://open.bigmodel.cn")!
        }
    }

    var displayName: String {
        switch self {
        case .global: L10n.text("datasource.zai_region_global")
        case .china: L10n.text("datasource.zai_region_china")
        }
    }

    static func parse(_ value: String?) -> Self? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if raw == "cn" || raw == "china" || raw == "bigmodel" || raw == "bigmodel-cn"
            || raw.contains("bigmodel.cn") {
            return .china
        }
        if raw == "global" || raw.contains("api.z.ai") { return .global }
        return nil
    }
}

struct ZAIRegionStore {
    static let defaultsKey = "tokenRemain.zai.apiRegion.v1"

    var defaults: UserDefaults = .standard
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func load() -> ZAIAPIRegion {
        for key in ["ZAI_API_REGION", "Z_AI_API_REGION", "Z_AI_API_HOST", "ZAI_API_HOST"] {
            if let region = ZAIAPIRegion.parse(environment[key]) { return region }
        }
        return ZAIAPIRegion.parse(defaults.string(forKey: Self.defaultsKey)) ?? .global
    }

    func save(_ region: ZAIAPIRegion) {
        defaults.set(region.rawValue, forKey: Self.defaultsKey)
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
        for name in ["ZAI_API_KEY", "Z_AI_API_KEY", "GLM_API_KEY", "ZHIPU_API_KEY"] {
            if let key = normalized(environment[name]) { return key }
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
