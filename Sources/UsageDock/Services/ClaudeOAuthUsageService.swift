import CryptoKit
import Foundation
import OSLog
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
        // Isolated profiles still read Keychain, but only the CLAUDE_CONFIG_DIR
        // scoped item. Claude Code 2.1+ no longer writes `.credentials.json`.
        let isolatedDirectory = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        reader.allowsKeychain = !isolatedConfiguration || !isolatedDirectory.isEmpty
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
            // `/logout` 之后 Claude Code 会保留 MCP 的 OAuth 段、删掉账号段:
            // 条目还在,但已经不是登录凭证。这是"登出",不是"格式无法识别"。
            if result.hasInvalidKeychainPayload && !result.keychainPayloadIsSignedOut {
                throw APIError.invalidStoredCredentials
            }
            throw APIError.credentialsUnavailable
        }

        var request = URLRequest(url: Self.usageURL)
        // 空闲超时。跨境链路偶发抖动下 10 秒经常刚好差一口气,一次抖动就
        // 把"请求超时"挂到卡片上;25 秒仍远短于一轮刷新,配合下面的一次
        // 重试足以吸收单次抖动。
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // 接口按 Claude Code 客户端的形态放行;裸 UA 会被部分网关拦截。
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.performWithOneTransportRetry(request)
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

    static let requestTimeout: TimeInterval = 25
    static let transportRetryDelay: TimeInterval = 2

    /// 传输层失败(超时、连接断开、DNS 失败)会自己恢复,和凭证或服务端
    /// 状态无关。只有这类错误值得在同一轮里重试一次;HTTP 状态码和解析
    /// 错误不走这里。
    static func isTransportFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed, .internationalRoamingOff, .callIsActive,
             .dataNotAllowed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// 一次传输失败后隔 `retryDelay` 再发一次同样的请求,第二次失败原样
    /// 抛出。只重试一次:连续两次都超时说明链路真的不通,再等下去只会拖
    /// 慢整轮刷新,交给下一轮即可。
    static func performWithOneTransportRetry(
        _ request: URLRequest,
        retryDelay: TimeInterval = transportRetryDelay,
        perform: (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        do {
            let response = try await perform(request)
            try Task.checkCancellation()
            return response
        } catch let error where isTransportFailure(error) {
            try Task.checkCancellation()
            if retryDelay > 0 {
                try await Task.sleep(for: .seconds(retryDelay))
            }
            try Task.checkCancellation()
            let response = try await perform(request)
            try Task.checkCancellation()
            return response
        }
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

/// oauth/usage 响应 → ProviderQuota。claude.ai 网页会话的
/// `organizations/<id>/usage` 返回同一结构,共用本解析器。
///
/// 解析按"服务端报了哪些额度行"自适应,不写死套餐或字段名:
/// - 旧字段按键名里的时长归类:`five_hour`、`seven_day`、`seven_day_<scope>`,
///   以及同一命名规则下任何新的时长(`one_day`、`thirty_day_<scope>` …)。
/// - 结构化 `limits[]` 按 `kind` / `group` 归类时长,按 `scope` 区分账户级
///   与分项(模型、使用入口)。Claude Code 自己的说明是"which meters apply
///   … are the server's … a new meter needs no client release"。
/// - 账户级窗口按时长从短到长填 `primary` / `secondary`;没有 5 小时窗的
///   套餐只剩周窗,周窗即 `primary`。其余行进 `scopedWindows`。
/// - 认不出的行只跳过那一行并留一条脱敏的结构日志,不拖累认得出的行。
///
/// 旧窗口使用 `utilization`,新窗口使用 `percent`;两者都是 0–100 已用百分比。
enum ClaudeOAuthUsageParser {
    static func parse(
        _ data: Data,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        now: Date = .now
    ) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            ClaudeUsageSchemaLog.report("response is not a JSON object", outcome: .rejected)
            throw ClaudeOAuthUsageService.APIError.invalidResponse
        }
        var meters = Meters()
        // Sorted so the scoped order, and therefore the card, is stable.
        for key in object.keys.sorted() {
            guard let shape = durationKey(key) else { continue }
            guard let window = meterWindow(object[key], windowMinutes: shape.minutes) else {
                continue
            }
            if let scope = shape.scope {
                meters.addScoped(
                    id: scope,
                    name: displayName(forScopeID: scope),
                    window: window,
                    now: now
                )
            } else {
                meters.addGeneral(window)
            }
        }
        for row in object["limits"] as? [Any] ?? [] {
            classify(row, into: &meters, now: now)
        }

        // Every window is nullable in the schema Claude Code 2.1.330 validates
        // against, and its /usage screen simply omits a row whose value is
        // null: plans without a 5-hour session cap answer with the weekly
        // window alone. Whatever general windows the server did report are the
        // account's quota — never synthesize a 0% window for a missing one.
        //
        // A payload with no general window at all is still rejected, so
        // inference-only tokens fall through to the PTY instead of inventing
        // subscription quota.
        let general = meters.general.values.sorted { $0.windowMinutes < $1.windowMinutes }
        guard let primary = general.first else {
            ClaudeUsageSchemaLog.report(schemaSummary(of: object), outcome: .rejected)
            throw ClaudeOAuthUsageService.APIError.invalidResponse
        }
        if !meters.skipped.isEmpty {
            ClaudeUsageSchemaLog.report(
                schemaSummary(of: object),
                outcome: .partiallyRecognized(meters.skipped)
            )
        }
        // The card has two general slots. A third account-wide cap (the help
        // center reserves the right to add monthly ones) still has to be
        // visible, so it rides along as a named row instead of being dropped.
        for extra in general.dropFirst(2) {
            meters.addScoped(id: "overall", name: "Overall", window: extra, now: now)
        }
        let scopedWindows = meters.scopedWindows
        return ProviderQuota(
            provider: .claude,
            primary: primary,
            secondary: general.dropFirst().first,
            planName: planName(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier),
            capturedAt: now,
            extraUsage: extraUsage(object["extra_usage"]),
            scopedWindows: scopedWindows.isEmpty ? nil : scopedWindows
        )
    }

    /// What one response contributed, before it is laid out as a quota.
    private struct Meters {
        /// Account-wide windows by duration. The first source to report a
        /// duration keeps it: legacy keys are read before `limits[]`, and they
        /// carry the unrounded value.
        var general: [Int: QuotaWindow] = [:]
        private var scopedOrder: [String] = []
        private var scopedByID: [String: ScopedQuotaWindow] = [:]
        /// Sanitized `kind/group` of rows that carried a reading but could not
        /// be classified. Never contains values.
        var skipped: [String] = []

        var scopedWindows: [ScopedQuotaWindow] { scopedOrder.compactMap { scopedByID[$0] } }

        mutating func addGeneral(_ window: QuotaWindow) {
            if general[window.windowMinutes] == nil {
                general[window.windowMinutes] = window
            }
        }

        /// Weekly rows keep the bare ID (`fable`), the convention every cache
        /// and synced snapshot already uses. Other durations get a suffix so a
        /// session and a weekly row for one model stay two rows; `_session`
        /// matches what the `/usage` screen parser emits.
        mutating func addScoped(id: String, name: String, window: QuotaWindow, now: Date) {
            guard let base = ClaudeOAuthUsageParser.normalizedScopeID(id) else { return }
            let suffix: String
            switch window.windowMinutes {
            case 10_080: suffix = ""
            case 300: suffix = "_session"
            default: suffix = "_" + ClaudeOAuthUsageParser.compactDuration(window.windowMinutes)
            }
            let scopeID = suffix.isEmpty ? base : String(base.prefix(32 - suffix.count)) + suffix
            if scopedByID[scopeID] == nil { scopedOrder.append(scopeID) }
            // A later source wins for the same row, as before: `limits[]`
            // carries the server's display name.
            scopedByID[scopeID] = ScopedQuotaWindow(
                scopeID: scopeID,
                displayName: name,
                window: window,
                observedAt: now
            )
        }
    }

    /// One `limits[]` row. Banners and help links share the array but carry no
    /// reading, so a row without a numeric percentage is not a meter at all.
    private static func classify(_ value: Any, into meters: inout Meters, now: Date) {
        guard let row = value as? [String: Any],
              let used = number(row["percent"]) ?? number(row["utilization"]) else {
            return
        }
        let kind = (row["kind"] as? String)?.lowercased() ?? ""
        let group = (row["group"] as? String)?.lowercased() ?? ""
        // What the kind says beyond its period: `weekly_all` → `all`,
        // `seven_day_opus` → `opus`, `session` → nothing.
        let qualifiers: Set<String>
        if let shape = durationKey(kind) {
            qualifiers = Set((shape.scope ?? "").split(separator: "_").map(String.init))
        } else {
            qualifiers = Set(kind.split(separator: "_").map(String.init))
                .subtracting(periodWords.keys)
        }
        // `weekly_notice` is the one non-meter kind seen so far: a banner that
        // happens to carry a percentage.
        guard !qualifiers.contains("notice") else { return }
        let tag = [kind, group].map(schemaToken).joined(separator: "/")
        guard let minutes = windowMinutes(kind: kind, group: group) else {
            meters.skipped.append(tag)
            return
        }
        let window = QuotaWindow(
            usedPercent: min(100, max(0, used)),
            windowMinutes: minutes,
            resetsAt: resetDate(row["resets_at"])
        )
        // A kind that spells out "all" is the account-wide row whatever its
        // scope object carries, as it was before rows were classified by scope.
        let isExplicitlyGeneral = !qualifiers.isEmpty && qualifiers.isSubset(of: generalQualifiers)
        let scope = isExplicitlyGeneral ? nil : scopeLabel(row["scope"])
        if let scope, qualifiers.isSubset(of: scopedQualifiers) {
            // `all models` under a scope is the general weekly cap restated.
            guard !ScopedQuotaWindow.isGeneralWeeklyLabel(scope.name) else { return }
            meters.addScoped(id: scope.id, name: scope.name, window: window, now: now)
        } else if scope == nil, qualifiers.isSubset(of: generalQualifiers) {
            meters.addGeneral(window)
        } else {
            // A scoped row without a name, or a qualifier this build has never
            // seen. It could be a slice of the account, or a second meter for
            // a model that already has one: shown as the account-wide window
            // it would misstate the whole account, and shown under the model's
            // name it would overwrite that model's real row. Skip it and say
            // so in the log; new periods, models and surfaces need no such
            // guess and are shown as they arrive.
            meters.skipped.append(tag)
        }
    }

    private static let scopedQualifiers: Set<String> = ["scoped"]

    /// `weekly_all` is the account-wide weekly cap and `session` carries no
    /// qualifier at all. These are the spellings accepted as "the whole
    /// account" for any period.
    private static let generalQualifiers: Set<String> = ["all", "models", "overall", "total", "general"]

    private static let periodWords: [String: Int] = [
        "session": 300, "hourly": 60, "daily": 1_440, "day": 1_440,
        "weekly": 10_080, "week": 10_080, "monthly": 43_200, "month": 43_200
    ]

    /// The window a row meters, from the server's own classification. `kind`
    /// is consulted before `group` because it is the more specific of the two.
    private static func windowMinutes(kind: String, group: String) -> Int? {
        for source in [kind, group] {
            if let shape = durationKey(source) { return shape.minutes }
            for token in source.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                if let minutes = periodWords[String(token)] { return minutes }
            }
        }
        return nil
    }

    /// `five_hour` → 300 minutes, account-wide. `seven_day_opus` → 10 080
    /// minutes scoped to `opus`. Any other `<count>_<unit>[_<scope>]` key
    /// follows the same rule, so a new window length needs no release.
    private static func durationKey(_ key: String) -> (minutes: Int, scope: String?)? {
        let parts = key.lowercased().split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let count = countWords[String(parts[0])] ?? Int(parts[0]),
              let unit = unitMinutes[String(parts[1])],
              count > 0 else {
            return nil
        }
        let minutes = count * unit
        // Longer than a year is not a rate-limit window.
        guard minutes <= 366 * 1_440 else { return nil }
        let scope = parts.dropFirst(2).joined(separator: "_")
        return (minutes, scope.isEmpty ? nil : scope)
    }

    private static let countWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12,
        "fourteen": 14, "fifteen": 15, "twenty": 20, "thirty": 30,
        "sixty": 60, "ninety": 90
    ]

    private static let unitMinutes: [String: Int] = [
        "minute": 1, "minutes": 1, "hour": 60, "hours": 60,
        "day": 1_440, "days": 1_440, "week": 10_080, "weeks": 10_080,
        "month": 43_200, "months": 43_200
    ]

    private static func compactDuration(_ minutes: Int) -> String {
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// What a scoped row is for. Today that is a model or a surface; any other
    /// dimension the server adds is named the same way. A model ID may be
    /// null (Fable's is), so the display name doubles as the stable ID.
    private static func scopeLabel(_ value: Any?) -> (id: String, name: String)? {
        guard let scope = value as? [String: Any] else { return nil }
        let known = ["model", "surface"]
        var ids: [String] = []
        var names: [String] = []
        for key in known + scope.keys.filter({ !known.contains($0) }).sorted() {
            guard let part = scope[key] as? [String: Any] else { continue }
            let rawID = nonEmpty(part["id"] as? String)
            let rawName = nonEmpty(part["display_name"] as? String)
            guard let name = rawName ?? rawID.map(displayName(forScopeID:)) else { continue }
            ids.append(rawID ?? name)
            names.append(name)
        }
        guard !names.isEmpty else { return nil }
        return (ids.joined(separator: "_"), names.joined(separator: " · "))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func displayName(forScopeID scopeID: String) -> String {
        scopeID.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func normalizedScopeID(_ value: String) -> String? {
        let normalized = value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return normalized.isEmpty ? nil : String(normalized.prefix(32))
    }

    /// Field names and row kinds only — never a value — so a response the
    /// parser could not use can be diagnosed from the log without capturing
    /// it. `five_hour=null seven_day={} limits=[3] | weekly_all/weekly …`.
    static func schemaSummary(of object: [String: Any]) -> String {
        let keys = object.keys.sorted().prefix(40).map { key -> String in
            let shape: String
            switch object[key] {
            case is NSNull: shape = "null"
            case let value as [String: Any]:
                let reading = number(value["utilization"]) ?? number(value["percent"])
                shape = reading == nil ? "{}" : "{%}"
            case let value as [Any]: shape = "[\(value.count)]"
            case is String: shape = "str"
            case is NSNumber: shape = "num"
            default: shape = "?"
            }
            return "\(schemaToken(key))=\(shape)"
        }
        let rows = (object["limits"] as? [Any] ?? []).prefix(32).map { value -> String in
            guard let row = value as? [String: Any] else { return "?" }
            var text = [row["kind"], row["group"]]
                .map { schemaToken($0 as? String ?? "") }
                .joined(separator: "/")
            if let scope = row["scope"] as? [String: Any] {
                let dimensions = scope.keys.sorted().filter { scope[$0] is [String: Any] }
                if !dimensions.isEmpty {
                    text += "[" + dimensions.map(schemaToken).joined(separator: ",") + "]"
                }
            }
            if number(row["percent"]) ?? number(row["utilization"]) == nil { text += "!" }
            return text
        }
        return keys.joined(separator: " ") + (rows.isEmpty ? "" : " | " + rows.joined(separator: " "))
    }

    /// Schema identifiers are short ASCII words. Anything that is not one is
    /// replaced outright rather than trimmed, so no fragment of free text can
    /// reach the log through a field name or a row kind.
    private static func schemaToken(_ value: String) -> String {
        guard !value.isEmpty else { return "-" }
        let isIdentifier = value.unicodeScalars.count <= 32 && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }
        return isIdentifier ? value : "?"
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

    /// A legacy top-level window: `{utilization, resets_at}`. A null
    /// utilization means the window does not apply to this account.
    private static func meterWindow(_ value: Any?, windowMinutes: Int) -> QuotaWindow? {
        guard let object = value as? [String: Any],
              let used = number(object["utilization"]) ?? number(object["percent"]) else {
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

/// 解析器遇到认不全的响应时留痕。只写字段名、行类型和形状,不写任何数值、
/// 账号或组织信息,所以可以用 `.public` 落到 unified log:
///
///     /usr/bin/log show --last 1h --predicate 'subsystem == "com.jamesli.usagedock" AND category == "ClaudeUsageSchema"'
///
/// 同一种结构每个进程只记一次——解析每分钟都会跑,重复的行没有信息量。
enum ClaudeUsageSchemaLog {
    enum Outcome {
        /// 没有任何账户级额度行,整个响应被拒绝。
        case rejected
        /// 额度照常产出,但有带读数的行没能归类(附它们的 kind/group)。
        case partiallyRecognized([String])
    }

    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "ClaudeUsageSchema")
    private static let reported = OSAllocatedUnfairLock(initialState: Set<String>())

    static func report(_ summary: String, outcome: Outcome) {
        let line: String
        switch outcome {
        case .rejected:
            line = "rejected: no account-wide window; schema: \(summary)"
        case .partiallyRecognized(let skipped):
            line = "skipped rows: \(skipped.prefix(16).joined(separator: " ")); schema: \(summary)"
        }
        let isNew = reported.withLock { seen -> Bool in
            // Bounded: a server that varies its shape on every call must not
            // grow this set, or the log, without limit.
            guard seen.count < 32 else { return false }
            return seen.insert(line).inserted
        }
        guard isNew else { return }
        logger.notice("Claude usage \(line, privacy: .public)")
    }
}

/// 只读发现 Claude Code 的 OAuth 凭证。查找顺序:
/// 1. `$CLAUDE_CONFIG_DIR/.credentials.json` 或 `~/.claude/.credentials.json`(无需授权提示)
/// 2. 钥匙串。默认家目录是 `Claude Code-credentials`;自定义
///    `CLAUDE_CONFIG_DIR` 是 `Claude Code-credentials-<sha256(path)[:8]>`。
///    自动刷新走 `.disallowed`:已在 ACL 里授权过的条目照常读到,未授权则立即
///    失败(绝不弹框、绝不阻塞)。构建脚本的稳定签名让"始终允许"跨重建生效。
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
        /// 钥匙串读到的是合法 JSON,只是没有 `claudeAiOauth` 账号段。
        var keychainPayloadIsSignedOut: Bool = false

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

    var keychainPayload: @Sendable (String, KeychainRead.Interaction) -> KeychainRead.Outcome = { service, interaction in
        KeychainRead.genericPassword(
            service: service,
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
        let outcome = keychainPayload(resolvedKeychainService, keychainInteraction)
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
            hasExpiredCredentials: foundExpiredCredentials,
            keychainPayloadIsSignedOut: parsed == nil
                && outcome.payload.map(Self.isSignedOutPayload) == true
        )
    }

    /// The direct read is cheaper and wins whenever this app really is inside the
    /// item's partition. When it is not — the normal state for a credential a CLI
    /// wrote, see `KeychainRead.genericPasswordViaAppleTool` — retry through
    /// `/usr/bin/security` rather than degrading to the PTY probe. Isolated
    /// profiles use the CLAUDE_CONFIG_DIR-scoped item; they must never fall
    /// through to the unsuffixed system-account service.
    func readAllowingAppleTool(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async -> ReadResult {
        let direct = read(now: now, keychainInteraction: keychainInteraction)
        guard allowsKeychain, direct.credentials == nil, direct.needsAuthorization else {
            return direct
        }
        let outcome = await appleToolPayload(resolvedKeychainService)
        guard let payload = outcome.payload else {
            // Keep the direct result: it already describes why the item is out
            // of reach, and the delegate adds no new recovery action.
            return direct
        }
        guard let parsed = Self.decode(payload) else {
            // 代读成功但内容不是登录凭证:要么已 /logout(只剩 mcpOAuth),
            // 要么格式真的变了。两者都不该再报"需要授权"。
            return ReadResult(
                credentials: nil,
                source: nil,
                keychainStatus: errSecSuccess,
                hasExpiredCredentials: false,
                keychainPayloadIsSignedOut: Self.isSignedOutPayload(payload)
            )
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

    /// 合法 JSON 对象,但没有可用的 `claudeAiOauth.accessToken`。Claude Code
    /// `/logout` 后就是这个形态(通常只剩 `mcpOAuth`)。
    static func isSignedOutPayload(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        guard let oauth = object["claudeAiOauth"] as? [String: Any] else { return true }
        let token = (oauth["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty
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

    /// Claude Code 2.1+ stores OAuth tokens in a Keychain item named after the
    /// configuration home. The default `~/.claude` directory keeps the historical
    /// unsuffixed service; any other `CLAUDE_CONFIG_DIR` gets
    /// `Claude Code-credentials-<sha256(path)[:8]>`. Hashing the path Claude
    /// itself received is what keeps a second account from inheriting the
    /// system login.
    static func keychainServiceName(
        configurationDirectory: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard var path = configurationDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return keychainService
        }
        if path.hasPrefix("~") {
            path = homeDirectory.path + path.dropFirst()
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let defaultPath = homeDirectory.appending(path: ".claude").path
        if path == defaultPath {
            return keychainService
        }
        let digest = SHA256.hash(data: Data(path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(keychainService)-\(suffix)"
    }

    private var resolvedKeychainService: String {
        Self.keychainServiceName(
            configurationDirectory: environment["CLAUDE_CONFIG_DIR"],
            homeDirectory: homeDirectory
        )
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
