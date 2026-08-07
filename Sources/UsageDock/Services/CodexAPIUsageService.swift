import CryptoKit
import Foundation
import Security

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
        case credentialsAuthorizationRequired
        case invalidStoredCredentials
        case tokenExpired
        case tokenRejected(Int)
        case requestFailed(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return L10n.text("service.codex.not_logged_in")
            case .credentialsAuthorizationRequired:
                return L10n.text("service.codex.authorization_required")
            case .invalidStoredCredentials:
                return L10n.text("service.codex.invalid_stored_credentials")
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

    func fetch(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async throws -> ProviderQuota {
        let result = CodexAuthReader().read(
            now: now,
            keychainInteraction: keychainInteraction
        )
        guard let auth = result.auth else {
            if result.needsAuthorization {
                throw APIError.credentialsAuthorizationRequired
            }
            if result.hasInvalidKeychainPayload {
                throw APIError.invalidStoredCredentials
            }
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
            capturedAt: now,
            codexResetCredits: resetCredits(object["rate_limit_reset_credits"])
        )
    }

    static func resetCredits(_ value: Any?) -> CodexRateLimitResetCredits? {
        guard let object = value as? [String: Any],
              let available = wholeNumber(object["available_count"])
        else {
            return nil
        }
        return CodexRateLimitResetCredits(
            availableCount: max(0, available)
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

    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = number(value), number.isFinite else { return nil }
        return Int(number.rounded(.towardZero))
    }
}

/// 只读发现 Codex 本地登录凭证。先保留历史兼容路径
/// `$CODEX_HOME/auth.json`(默认 `~/.codex/auth.json`),文件不可用时再读取
/// Codex 当前 macOS keyring 条目。ChatGPT 桌面端、Codex CLI 和 IDE
/// 扩展都可以由 Codex 自己维护这份凭证;TokenRemain 绝不刷新或写回。
/// access token 是 JWT,读取 `exp` 声明做过期预检,避免注定 401 的请求。
struct CodexAuthReader {
    enum Source: Equatable, Sendable {
        case file
        case keychain
    }

    struct Auth: Sendable {
        let accessToken: String
        let accountID: String?
        let accessTokenExpiry: Date?
    }

    struct ReadResult: Sendable {
        let auth: Auth?
        let source: Source?
        let keychainStatus: OSStatus?

        var needsAuthorization: Bool {
            guard let keychainStatus else { return false }
            return keychainStatus == errSecAuthFailed
                || keychainStatus == errSecInteractionNotAllowed
                || keychainStatus == errSecUserCanceled
        }

        var hasInvalidKeychainPayload: Bool {
            keychainStatus == errSecSuccess && auth == nil
        }
    }

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    static let keychainService = "Codex Auth"

    var keychainPayload: @Sendable (String, KeychainRead.Interaction) -> KeychainRead.Outcome = {
        account, interaction in
        KeychainRead.genericPassword(
            service: CodexAuthReader.keychainService,
            account: account,
            interaction: interaction
        )
    }

    func load(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) -> Auth? {
        read(now: now, keychainInteraction: keychainInteraction).auth
    }

    func read(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) -> ReadResult {
        let fileAuth = (try? Data(contentsOf: authFileURL())).flatMap(Self.parse)
        if let fileAuth, !Self.isExpired(fileAuth, now: now) {
            return ReadResult(auth: fileAuth, source: .file, keychainStatus: nil)
        }

        let outcome = keychainPayload(keychainAccount(), keychainInteraction)
        let keychainAuth = outcome.payload
            .flatMap { $0.data(using: .utf8) }
            .flatMap(Self.parse)
        if let keychainAuth, !Self.isExpired(keychainAuth, now: now) {
            return ReadResult(
                auth: keychainAuth,
                source: .keychain,
                keychainStatus: outcome.status
            )
        }

        // 两条路径都不可用时保留已过期的结构化凭证,让上层报出
        // "token 已过期"而不是误报"未登录";Keychain 状态仍保留给显式授权 UI。
        let fallback = fileAuth.map { ($0, Source.file) }
            ?? keychainAuth.map { ($0, Source.keychain) }
        return ReadResult(
            auth: fallback?.0,
            source: fallback?.1,
            keychainStatus: outcome.status
        )
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

    private static func isExpired(_ auth: Auth, now: Date) -> Bool {
        auth.accessTokenExpiry.map { $0 <= now } ?? false
    }

    private func authFileURL() -> URL {
        codexHomeURL().appending(path: "auth.json")
    }

    private func codexHomeURL() -> URL {
        guard let configured = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty else {
            return homeDirectory.appending(path: ".codex")
        }
        let expanded = configured.hasPrefix("~")
            ? homeDirectory.path + configured.dropFirst()
            : configured
        return URL(fileURLWithPath: String(expanded))
    }

    /// Codex 将 canonical CODEX_HOME 的 SHA-256 前 16 个十六进制字符用作
    /// keyring account:`cli|<digest>`。路径不存在时与 Codex 一样使用标准化路径。
    func keychainAccount() -> String {
        let url = codexHomeURL()
        let canonicalURL: URL
        if FileManager.default.fileExists(atPath: url.path) {
            canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        } else {
            canonicalURL = url.standardizedFileURL
        }
        let digest = SHA256.hash(data: Data(canonicalURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "cli|\(digest.prefix(16))"
    }
}
