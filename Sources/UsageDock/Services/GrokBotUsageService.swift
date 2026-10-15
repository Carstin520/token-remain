import Foundation
import OSLog

/// Grok Bot(`com.anysphere.sand`,SpaceXAI 出品,跑在 Cursor 后端)周额度直查。
/// 与 Grok CLI(`GrokUsageService`,cli-chat-proxy.grok.com)是两条独立链路。
///
/// 凭证:复用 `CursorAuthReader` 只读拿到的 Cursor IDE access token,**不读**
/// Grok Bot 自己的 `sand-secrets.json`——那份文件由 Electron safeStorage 加密,
/// 解密会弹钥匙串授权,违背后台采集不交互的原则。代价:只有 Grok Bot 与
/// Cursor IDE 登录同一个 Cursor 账户时,读到的才是 Grok Bot 的额度。
/// 与 Cursor 一样绝不代刷 token;过期时提示打开 Cursor 让它自己续期。
struct GrokBotUsageService {
    enum ServiceError: LocalizedError, Sendable, Equatable {
        case notLoggedIn
        case staleLogin
        case requestFailed(Int)
        case invalidResponse
        /// 响应里没有 `usage_percent`:该账户没有 Grok Bot 周额度。
        case noWeeklyAllowance
        /// 团队共享池:Grok Bot 自己也不展示周百分比,这里同样不伪造一个。
        case pooledAllowance

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return L10n.text("service.grok_bot.not_logged_in")
            case .staleLogin:
                return L10n.format("service.common.stale_login_reopen", "Cursor")
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed", "Grok Bot", status)
            case .invalidResponse:
                return L10n.format("service.common.invalid_response", "Grok Bot")
            case .noWeeklyAllowance:
                return L10n.text("service.grok_bot.no_weekly_allowance")
            case .pooledAllowance:
                return L10n.text("service.grok_bot.pooled_allowance")
            }
        }
    }

    private static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "GrokBotUsage")

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    var loadAuth: @Sendable () async -> CursorAuthReader.Auth? = { await CursorAuthReader().load() }
    /// 单次请求 10 秒;整轮刷新另由 `UsageStore.fetchAux` 的 `AsyncDeadline` 兜底,
    /// 超时只保留旧缓存,不等于凭证失效。
    var transport: Transport = { try await URLSession.shared.data(for: $0) }

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let auth = await loadAuth() else {
            throw ServiceError.notLoggedIn
        }
        if let expiry = JWT.expiry(auth.accessToken), expiry <= now {
            Self.logger.info("Cursor access token expired; waiting for Cursor to renew it")
            throw ServiceError.staleLogin
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 10
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ServiceError.staleLogin
        default:
            throw ServiceError.requestFailed(http.statusCode)
        }
        let quota = try GrokBotUsageParser.parse(data, now: now)
        Self.logger.info("Grok Bot quota served by DashboardService API")
        return quota
    }
}

/// GetSandUsageStatus(Connect JSON,字段为 lowerCamelCase)→ ProviderQuota。
/// 与 Grok Bot 自己的映射一致:`usagePercent` 为周已用百分比(0–100,Grok Bot
/// 只做 `max(_, 0)`),`nextResetTimestampUtc` 为下次周重置
/// (google.protobuf.Timestamp,JSON 中是 RFC 3339 字符串);共享企业池或
/// 缺 `usagePercent` 时 Grok Bot 不展示周额度,这里抛对应错误而不是显示 0%。
/// 计划名优先 `grokPlanLabel`(如 `super`、`unified_ultra`),缺省回落
/// `cursorPlanName`。
enum GrokBotUsageParser {
    static let weeklyWindowMinutes = 7 * 24 * 60

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GrokBotUsageService.ServiceError.invalidResponse
        }
        if object["usesPooledEnterpriseAllowance"] as? Bool == true {
            throw GrokBotUsageService.ServiceError.pooledAllowance
        }
        guard let usagePercent = number(object["usagePercent"]), usagePercent.isFinite else {
            throw GrokBotUsageService.ServiceError.noWeeklyAllowance
        }
        let resetsAt = timestamp(object["nextResetTimestampUtc"])
            .flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        return ProviderQuota(
            provider: .grokBot,
            primary: QuotaWindow(
                usedPercent: min(100, max(0, usagePercent)),
                windowMinutes: weeklyWindowMinutes,
                resetsAt: resetsAt
            ),
            secondary: nil,
            planName: planLabel(object["grokPlanLabel"] as? String)
                ?? planLabel(object["cursorPlanName"] as? String),
            capturedAt: now
        )
    }

    /// "unified_ultra" → "Unified Ultra";"super" → "Super"。
    static func planLabel(_ value: String?) -> String? {
        CursorAPIUsageParser.planLabel(value?.replacingOccurrences(of: "_", with: " "))
    }

    /// protobuf JSON 的 Timestamp 小数位可为 0/3/6/9;Foundation 的
    /// ISO8601DateFormatter 只认毫秒,先把小数截到 3 位再解析。
    static func timestamp(_ value: Any?) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        let normalized = text.replacingOccurrences(
            of: #"\.(\d{1,3})\d*"#,
            with: ".$1",
            options: .regularExpression
        )
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: normalized) ?? ISO8601DateFormatter().date(from: normalized)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
