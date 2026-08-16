import Foundation
import Security

/// Claude 限额 API 直查。参考 OpenUsage(MIT)的 provider pipeline:
/// 只读 Claude Code 已有的 OAuth access token,调用官方 oauth/usage 接口
/// 获取结构化的 5 小时 / 7 天限额。
///
/// 约束:绝不刷新 token、绝不写回凭证。续期始终由 Claude Code 自己完成,
/// UsageDock 不会与它争用 refresh token,也不会触发第三方续期限流。
/// token 过期时由调用方降级到 PTY `/usage` 探针(探针会让 Claude Code
/// 自行续期,下一轮 API 直查即可恢复)。
struct ClaudeOAuthUsageService {
    enum APIError: LocalizedError, Sendable {
        case credentialsUnavailable
        case credentialsAuthorizationRequired
        case credentialsExpired
        case invalidStoredCredentials
        case tokenRejected(Int)
        case rateLimited(retryAfterSeconds: Int?)
        case requestFailed(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .credentialsUnavailable:
                return L10n.text("service.claude.credentials_unavailable")
            case .credentialsAuthorizationRequired:
                return L10n.text("service.claude.authorization_required")
            case .credentialsExpired:
                return L10n.text("service.claude.session_expired")
            case .invalidStoredCredentials:
                return L10n.text("service.claude.invalid_stored_credentials")
            case .tokenRejected(let status):
                return L10n.format("service.common.token_rejected_plain", "Claude", status)
            case .rateLimited(let seconds):
                if let seconds {
                    return L10n.format("service.claude.api_rate_limited_minutes", max(1, Int(ceil(Double(seconds) / 60))))
                }
                return L10n.text("service.claude.api_rate_limited")
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed_plain", "Claude", status)
            case .invalidResponse:
                return L10n.format("service.common.invalid_response", "Claude")
            }
        }
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isolatedConfiguration: Bool = false
    ) async throws -> ProviderQuota {
        var reader = ClaudeCredentialsReader()
        reader.environment = environment
        reader.fallbackToDefaultDirectory = !isolatedConfiguration
        reader.allowsKeychain = !isolatedConfiguration
        let result = await reader.readAllowingAppleTool(
            now: now,
            keychainInteraction: keychainInteraction
        )
        guard let credentials = result.credentials else {
            if result.needsAuthorization {
                throw APIError.credentialsAuthorizationRequired
            }
            if result.hasExpiredCredentials {
                throw APIError.credentialsExpired
            }
            if result.hasInvalidKeychainPayload {
                throw APIError.invalidStoredCredentials
            }
            throw APIError.credentialsUnavailable
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // 接口按 Claude Code 客户端的形态放行;裸 UA 会被部分网关拦截。
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw APIError.tokenRejected(http.statusCode)
        case 429:
            throw APIError.rateLimited(retryAfterSeconds: Self.retryAfterSeconds(http, now: now))
        default:
            throw APIError.requestFailed(http.statusCode)
        }
        return try ClaudeOAuthUsageParser.parse(
            data,
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            now: now
        )
    }

    static func retryAfterSeconds(_ response: HTTPURLResponse, now: Date = .now) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = Int(raw), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, Int(ceil(date.timeIntervalSince(now))))
    }
}

/// oauth/usage 响应 → ProviderQuota。兼容旧的 `five_hour` / `seven_day` /
/// `seven_day_<scope>` 字段和新的结构化 `limits` 数组。旧窗口使用
/// `utilization`,新窗口使用 `percent`;两者都是 0–100 已用百分比。
enum ClaudeOAuthUsageParser {
    static func parse(
        _ data: Data,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        now: Date = .now
    ) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeOAuthUsageService.APIError.invalidResponse
        }
        let structured = structuredLimits(object["limits"], now: now)
        // Some accounts have moved these values into `limits`; require a real
        // session row from either schema so inference-only tokens still fall
        // through to the PTY instead of inventing subscription quota.
        guard let primary = window(object["five_hour"], windowMinutes: 300, now: now)
            ?? structured.primary else {
            throw ClaudeOAuthUsageService.APIError.invalidResponse
        }
        let secondary = window(object["seven_day"], windowMinutes: 10_080, now: now)
            ?? structured.secondary
        let legacyScopedWindows = object.keys.sorted().compactMap { key -> ScopedQuotaWindow? in
            let prefix = "seven_day_"
            guard key.hasPrefix(prefix), key.count > prefix.count,
                  let value = window(object[key], windowMinutes: 10_080, now: now) else {
                return nil
            }
            let scopeID = String(key.dropFirst(prefix.count)).lowercased()
            return ScopedQuotaWindow(
                scopeID: scopeID,
                displayName: displayName(forScopeID: scopeID),
                window: value,
                observedAt: now
            )
        }
        let scopedWindows = uniqueScopedWindows(legacyScopedWindows + structured.scopedWindows)
        return ProviderQuota(
            provider: .claude,
            primary: primary,
            secondary: secondary,
            planName: planName(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier),
            capturedAt: now,
            extraUsage: extraUsage(object["extra_usage"]),
            scopedWindows: scopedWindows.isEmpty ? nil : scopedWindows
        )
    }

    private static func displayName(forScopeID scopeID: String) -> String {
        scopeID.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private struct StructuredLimits {
        var primary: QuotaWindow?
        var secondary: QuotaWindow?
        var scopedWindows: [ScopedQuotaWindow] = []
    }

    /// The current API represents Fable as a `weekly_scoped` row whose model
    /// ID may be null. Derive a stable ID from the display name in that case;
    /// banners and help links are not rows in this schema and are ignored.
    private static func structuredLimits(_ value: Any?, now: Date) -> StructuredLimits {
        guard let rows = value as? [[String: Any]] else { return StructuredLimits() }
        var result = StructuredLimits()
        for row in rows {
            switch (row["kind"] as? String)?.lowercased() {
            case "session":
                if let window = limitWindow(row, windowMinutes: 300) {
                    result.primary = window
                }
            case "weekly_all":
                if let window = limitWindow(row, windowMinutes: 10_080) {
                    result.secondary = window
                }
            case "weekly_scoped":
                guard let window = limitWindow(row, windowMinutes: 10_080),
                      let scope = row["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any] else {
                    continue
                }
                let rawID = (model["id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rawName = (model["display_name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedDisplayName = rawName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? rawID.flatMap { $0.isEmpty ? nil : Self.displayName(forScopeID: $0) }
                guard let resolvedDisplayName,
                      !ScopedQuotaWindow.isGeneralWeeklyLabel(resolvedDisplayName),
                      let scopeID = normalizedScopeID(
                          rawID.flatMap { $0.isEmpty ? nil : $0 } ?? resolvedDisplayName
                      ) else {
                    continue
                }
                result.scopedWindows.append(
                    ScopedQuotaWindow(
                        scopeID: scopeID,
                        displayName: resolvedDisplayName,
                        window: window,
                        observedAt: now
                    )
                )
            default:
                continue
            }
        }
        return result
    }

    private static func limitWindow(_ object: [String: Any], windowMinutes: Int) -> QuotaWindow? {
        guard let used = number(object["percent"]) ?? number(object["utilization"]) else {
            return nil
        }
        return QuotaWindow(
            usedPercent: min(100, max(0, used)),
            windowMinutes: windowMinutes,
            resetsAt: resetDate(object["resets_at"])
        )
    }

    private static func normalizedScopeID(_ value: String) -> String? {
        let normalized = value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return normalized.isEmpty ? nil : String(normalized.prefix(32))
    }

    private static func uniqueScopedWindows(_ windows: [ScopedQuotaWindow]) -> [ScopedQuotaWindow] {
        var order: [String] = []
        var latestByID: [String: ScopedQuotaWindow] = [:]
        for window in windows {
            let key = window.scopeID.lowercased()
            if latestByID[key] == nil { order.append(key) }
            latestByID[key] = window
        }
        return order.compactMap { latestByID[$0] }
    }

    /// `extra_usage {is_enabled, used_credits, monthly_limit}`(美分)→ 附加
    /// 消费。未开通或从未花过且无上限时返回 nil,卡片不渲染多余行。
    static func extraUsage(_ value: Any?) -> ExtraUsage? {
        guard let object = value as? [String: Any],
              object["is_enabled"] as? Bool == true,
              let spentCents = number(object["used_credits"]) else {
            return nil
        }
        let limitCents = number(object["monthly_limit"])
        let limit = (limitCents ?? 0) > 0 ? limitCents! / 100 : nil
        guard spentCents > 0 || limit != nil else { return nil }
        return ExtraUsage(spentUSD: spentCents / 100, monthlyLimitUSD: limit)
    }

    /// "max" + "default_20x" → "Max 20x";没有 tier 时只显示订阅类型。
    static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let base = raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
        guard let tier = rateLimitTier,
              let match = tier.range(of: #"\d+x"#, options: .regularExpression) else {
            return base
        }
        return "\(base) \(tier[match])"
    }

    private static func window(_ value: Any?, windowMinutes: Int, now: Date) -> QuotaWindow? {
        guard let object = value as? [String: Any],
              let used = number(object["utilization"]) else {
            return nil
        }
        return QuotaWindow(
            usedPercent: min(100, max(0, used)),
            windowMinutes: windowMinutes,
            resetsAt: resetDate(object["resets_at"])
        )
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return iso8601Fractional.date(from: text) ?? iso8601.date(from: text)
        }
        guard let raw = number(value), raw.isFinite, raw > 0 else { return nil }
        // epoch 秒或毫秒都接受;1e10 之前是 2286 年,足以区分两种单位。
        let seconds = raw < 1e10 ? raw : raw / 1000
        return Date(timeIntervalSince1970: seconds)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// 只读发现 Claude Code 的 OAuth 凭证。查找顺序:
/// 1. `$CLAUDE_CONFIG_DIR/.credentials.json` 或 `~/.claude/.credentials.json`(无需授权提示)
/// 2. 钥匙串 `Claude Code-credentials`。自动刷新走 `.disallowed`:已在 ACL 里
///    授权过的条目照常读到,未授权则立即失败(绝不弹框、绝不阻塞)。构建脚本
///    的稳定签名让"始终允许"跨重建生效。
/// 3. 同一条目改由 `/usr/bin/security` 代读(`readAllowingAppleTool`)。第 2 步
///    在实机上恒定失败:该条目的 partition list 只有 `apple-tool:`,分区检查先于
///    信任应用检查,于是"始终允许"点多少次都不生效。见
///    `KeychainRead.genericPasswordViaAppleTool`。
/// 三步都拿不到才由调用方降级到 PTY `/usage` 探针。
/// 已过期(或即将过期)的 token 直接跳过,继续尝试下一个来源;绝不续期。
struct ClaudeCredentialsReader {
    enum Source: Equatable, Sendable {
        case file
        case keychain
    }

    struct Credentials: Sendable {
        let accessToken: String
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    struct ReadResult: Sendable {
        let credentials: Credentials?
        let source: Source?
        let keychainStatus: OSStatus?
        let hasExpiredCredentials: Bool

        var needsAuthorization: Bool {
            guard let keychainStatus else { return false }
            return keychainStatus == errSecAuthFailed
                || keychainStatus == errSecInteractionNotAllowed
                || keychainStatus == errSecUserCanceled
        }

        var hasInvalidKeychainPayload: Bool {
            keychainStatus == errSecSuccess
                && credentials == nil
                && !hasExpiredCredentials
        }
    }

    private struct ParsedCredentials {
        let credentials: Credentials
        let expiresAt: Date?
    }

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Managed profiles must never fall through to the user's active account.
    /// The default remains true for the historical system-account reader.
    var fallbackToDefaultDirectory = true
    var allowsKeychain = true
    static let keychainService = "Claude Code-credentials"

    var keychainPayload: @Sendable (KeychainRead.Interaction) -> KeychainRead.Outcome = { interaction in
        KeychainRead.genericPassword(
            service: ClaudeCredentialsReader.keychainService,
            interaction: interaction
        )
    }

    var appleToolPayload: @Sendable (String) async -> KeychainRead.Outcome = { service in
        await KeychainRead.genericPasswordViaAppleTool(service: service)
    }

    /// token 剩余寿命低于该值时视同过期:一次刷新周期内的边界 token
    /// 会在请求途中失效,不如直接走降级路径。
    static let expiryMargin: TimeInterval = 120

    func load(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) -> Credentials? {
        read(now: now, keychainInteraction: keychainInteraction).credentials
    }

    func read(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) -> ReadResult {
        var foundExpiredCredentials = false
        for payload in filePayloads() {
            guard let parsed = Self.decode(payload) else { continue }
            if Self.isUsable(parsed, now: now) {
                return ReadResult(
                    credentials: parsed.credentials,
                    source: .file,
                    keychainStatus: nil,
                    hasExpiredCredentials: false
                )
            }
            foundExpiredCredentials = true
        }
        guard allowsKeychain else {
            return ReadResult(
                credentials: nil,
                source: nil,
                keychainStatus: nil,
                hasExpiredCredentials: foundExpiredCredentials
            )
        }
        // 自动额度刷新永远不应召唤系统密码框。已选择过“始终允许”的钥匙串
        // 项目仍能成功读取；尚未授权时立即静默失败，由调用方降级到 Claude
        // CLI /usage 探针。只有明确的用户操作才能传 `.allowed`。
        let outcome = keychainPayload(keychainInteraction)
        let parsed = outcome.payload.flatMap(Self.decode)
        let credentials = parsed.flatMap {
            Self.isUsable($0, now: now) ? $0.credentials : nil
        }
        foundExpiredCredentials = foundExpiredCredentials
            || (parsed != nil && credentials == nil)
        return ReadResult(
            credentials: credentials,
            source: credentials == nil ? nil : .keychain,
            keychainStatus: outcome.status,
            hasExpiredCredentials: foundExpiredCredentials
        )
    }

    /// The direct read is cheaper and wins whenever this app really is inside the
    /// item's partition. When it is not — the normal state for a credential a CLI
    /// wrote, see `KeychainRead.genericPasswordViaAppleTool` — retry through
    /// `/usr/bin/security` rather than degrading to the PTY probe. Managed
    /// profiles never take this path: their credentials live in their own
    /// configuration directory, while the shared keychain item belongs to
    /// whichever account Claude Code is currently signed into.
    func readAllowingAppleTool(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async -> ReadResult {
        let direct = read(now: now, keychainInteraction: keychainInteraction)
        guard allowsKeychain, direct.credentials == nil, direct.needsAuthorization else {
            return direct
        }
        let outcome = await appleToolPayload(Self.keychainService)
        guard let payload = outcome.payload, let parsed = Self.decode(payload) else {
            // Keep the direct result: it already describes why the item is out
            // of reach, and the delegate adds no new recovery action.
            return direct
        }
        guard Self.isUsable(parsed, now: now) else {
            return ReadResult(
                credentials: nil,
                source: nil,
                keychainStatus: outcome.status,
                hasExpiredCredentials: true
            )
        }
        return ReadResult(
            credentials: parsed.credentials,
            source: .keychain,
            keychainStatus: outcome.status,
            hasExpiredCredentials: false
        )
    }

    static func parse(_ payload: String, now: Date = .now) -> Credentials? {
        guard let parsed = decode(payload), isUsable(parsed, now: now) else {
            return nil
        }
        return parsed.credentials
    }

    private static func decode(_ payload: String) -> ParsedCredentials? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let accessToken = (oauth["accessToken"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            // Claude Code 写入的是 epoch 毫秒。
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return ParsedCredentials(
            credentials: Credentials(
                accessToken: accessToken,
                subscriptionType: oauth["subscriptionType"] as? String,
                rateLimitTier: oauth["rateLimitTier"] as? String
            ),
            expiresAt: expiresAt
        )
    }

    private static func isUsable(_ parsed: ParsedCredentials, now: Date) -> Bool {
        parsed.expiresAt.map { $0.timeIntervalSince(now) > expiryMargin } ?? true
    }

    private func filePayloads() -> [String] {
        var directories: [URL] = []
        if let configDir = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configDir.isEmpty {
            let expanded = configDir.hasPrefix("~")
                ? homeDirectory.path + configDir.dropFirst()
                : configDir
            directories.append(URL(fileURLWithPath: String(expanded)))
        }
        if fallbackToDefaultDirectory {
            directories.append(homeDirectory.appending(path: ".claude"))
        }
        return directories.compactMap { directory in
            try? String(
                contentsOf: directory.appending(path: ".credentials.json"),
                encoding: .utf8
            )
        }
    }

}
