import Foundation

/// Codex 限额 API 直查。参考 OpenUsage(MIT)的 Codex provider:
/// 只读 Codex CLI 已有的 OAuth access token,调用 ChatGPT 后端的
/// wham/usage 接口获取实时的 5 小时 + 7 天窗口(本地会话快照只在
/// 服务端事件出现时更新,可能滞后或缺窗口)。
///
/// 约束:绝不刷新 token、绝不写回 auth.json。token 过期(JWT `exp`
/// 预检或服务端 401)时由调用方降级到会话快照扫描。
struct CodexAPIUsageService {
    enum APIError: LocalizedError, Sendable {
        case notLoggedIn
        case tokenExpired
        case tokenRejected(Int)
        case requestFailed(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return L10n.text("service.codex.not_logged_in")
            case .tokenExpired:
                return L10n.text("service.codex.token_expired")
            case .tokenRejected(let status):
                return L10n.format("service.common.token_rejected_plain", "Codex", status)
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed_plain", "Codex", status)
            case .invalidResponse:
                return L10n.format("service.common.invalid_response", "Codex")
            }
        }
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let auth = CodexAuthReader().load() else {
            throw APIError.notLoggedIn
        }
        if let expiry = auth.accessTokenExpiry, expiry <= now {
            throw APIError.tokenExpired
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw APIError.tokenRejected(http.statusCode)
        default:
            throw APIError.requestFailed(http.statusCode)
        }
        return try CodexAPIUsageParser.parse(data, now: now)
    }
}

/// wham/usage 响应 → ProviderQuota。窗口位于 `rate_limit.primary_window` /
/// `rate_limit.secondary_window`,字段:`used_percent`、`limit_window_seconds`、
/// `reset_at`(epoch 秒)或 `reset_after_seconds`(相对秒)。
///
/// 常态是 primary=5 小时、secondary=7 天,但服务端在只剩单个周窗口时
/// 会把它挪进 primary 槽位,所以优先按 `limit_window_seconds` 分类,
/// 槽位顺序只作为老响应的兼容回退——与本地快照解析里
/// `limit_id` 的防错思路一致。
enum CodexAPIUsageParser {
    private static let sessionSeconds = 300 * 60
    private static let weeklySeconds = 10_080 * 60

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CodexAPIUsageService.APIError.invalidResponse
        }
        let rateLimit = object["rate_limit"] as? [String: Any]
        let candidates: [(window: [String: Any], fallbackSession: Bool)] = [
            (rateLimit?["primary_window"], true),
            (rateLimit?["secondary_window"], false)
        ].compactMap { value, fallbackSession in
            guard let window = value as? [String: Any] else { return nil }
            return (window, fallbackSession)
        }

        let session = classified(candidates, seconds: sessionSeconds, fallbackSession: true, now: now)
        let weekly = classified(candidates, seconds: weeklySeconds, fallbackSession: false, now: now)

        // 会话窗口缺席时(例如服务端只发布周窗口)让周窗口顶上 primary,
        // windowMinutes 会如实告诉 UI 这是 7 天窗口。
        guard let primary = session ?? weekly else {
            throw CodexAPIUsageService.APIError.invalidResponse
        }
        let secondary = session == nil ? nil : weekly
        return ProviderQuota(
            provider: .codex,
            primary: primary,
            secondary: secondary,
            planName: planName(object["plan_type"]),
            capturedAt: now
        )
    }

    /// "prolite" → "Pro 5x"、"pro" → "Pro 20x",与 Codex 自家产品页的叫法一致。
    static func planName(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        default:
            return raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private static func classified(
        _ candidates: [(window: [String: Any], fallbackSession: Bool)],
        seconds: Int,
        fallbackSession: Bool,
        now: Date
    ) -> QuotaWindow? {
        let exact = candidates.first { windowSeconds($0.window) == seconds }
        let fallback = candidates.first {
            windowSeconds($0.window) == nil && $0.fallbackSession == fallbackSession
        }
        guard let candidate = exact ?? fallback else { return nil }
        return quotaWindow(candidate.window, defaultSeconds: seconds, now: now)
    }

    private static func quotaWindow(_ window: [String: Any], defaultSeconds: Int, now: Date) -> QuotaWindow? {
        guard let used = number(window["used_percent"]) else { return nil }
        let seconds = windowSeconds(window) ?? defaultSeconds
        return QuotaWindow(
            usedPercent: min(100, max(0, used)),
            windowMinutes: seconds / 60,
            resetsAt: resetDate(window, now: now)
        )
    }

    private static func windowSeconds(_ window: [String: Any]) -> Int? {
        guard let seconds = number(window["limit_window_seconds"]), seconds > 0 else { return nil }
        return Int(seconds)
    }

    private static func resetDate(_ window: [String: Any], now: Date) -> Date? {
        if let resetAt = number(window["reset_at"]), resetAt > 0 {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let after = number(window["reset_after_seconds"]), after >= 0 {
            return now.addingTimeInterval(after)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// 只读发现 Codex CLI 的登录凭证:`$CODEX_HOME/auth.json`,默认 `~/.codex/auth.json`。
/// access token 是 JWT,读取 `exp` 声明做过期预检,避免注定 401 的请求。
struct CodexAuthReader {
    struct Auth: Sendable {
        let accessToken: String
        let accountID: String?
        let accessTokenExpiry: Date?
    }

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    func load() -> Auth? {
        guard let data = try? Data(contentsOf: authFileURL()) else { return nil }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> Auth? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }
        return Auth(
            accessToken: accessToken,
            accountID: tokens["account_id"] as? String,
            accessTokenExpiry: jwtExpiry(accessToken)
        )
    }

    static func jwtExpiry(_ token: String) -> Date? {
        JWT.expiry(token)
    }

    private func authFileURL() -> URL {
        if let home = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            let expanded = home.hasPrefix("~")
                ? homeDirectory.path + home.dropFirst()
                : home
            return URL(fileURLWithPath: String(expanded)).appending(path: "auth.json")
        }
        return homeDirectory.appending(path: ".codex/auth.json")
    }
}
