import CryptoKit
import Foundation
import OSLog

/// token-monitor 兼容层:DeepSeek / Kimi / MiniMax / MiMo / Qoder / Kiro /
/// Volcengine / Ollama 八家的限额直查。口径逐一对照
/// github.com/Javis603/token-monitor(MIT)的实现移植;凭据一律只读
/// (环境变量或用户粘贴的钥匙串条目),绝不写回、绝不代刷。
///
/// 与主力 provider 不同,这批服务体量小、结构同构,集中在本文件维护,
/// 接口变动时对照 token-monitor `src/shared/*Limits.js` 同步。
enum ExtendedProviderError: LocalizedError, Sendable {
    case notConfigured(ProviderQuota.Provider)
    case secretRejected(ProviderQuota.Provider, Int)
    case requestFailed(ProviderQuota.Provider, Int)
    case invalidResponse(ProviderQuota.Provider)
    case invalidSecret(ProviderQuota.Provider, detail: String)
    case notInstalled(ProviderQuota.Provider, hint: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider):
            return L10n.format("service.common.secret_missing", provider.displayName)
        case .secretRejected(let provider, let status):
            return L10n.format("service.common.secret_rejected", provider.displayName, status)
        case .requestFailed(let provider, let status):
            return L10n.format("service.common.request_failed", provider.displayName, status)
        case .invalidResponse(let provider):
            return L10n.format("service.common.invalid_response", provider.displayName)
        case .invalidSecret(_, let detail):
            return detail
        case .notInstalled(_, let hint):
            return hint
        }
    }
}

/// 共享 HTTP 小工具:发请求、统一 401/403 → secretRejected 语义。
enum ExtendedHTTP {
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Reuse connections for providers that must observe 3xx responses instead
    /// of following them to a login page or a credential-exfiltration target.
    private static let noRedirectSession = URLSession(
        configuration: .ephemeral,
        delegate: NoRedirectDelegate(),
        delegateQueue: nil
    )

    static func request(
        _ provider: ProviderQuota.Provider,
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 12,
        followRedirects: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let session = followRedirects ? URLSession.shared : noRedirectSession
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExtendedProviderError.invalidResponse(provider)
        }
        switch http.statusCode {
        case 200..<300: return data
        case 300..<400 where !followRedirects,
             401, 403:
            throw ExtendedProviderError.secretRejected(provider, http.statusCode)
        default: throw ExtendedProviderError.requestFailed(provider, http.statusCode)
        }
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func clamp(_ percent: Double) -> Double { min(100, max(0, percent)) }
}

// MARK: - DeepSeek(API Key,预充余额)

/// `GET api.deepseek.com/user/balance`。DeepSeek 是纯按量余额、无窗口上限:
/// 进度条只承载"有/无余额"的可用性,主数值直接展示剩余金额。
struct DeepSeekUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(apiKey: nil, now: now)
    }

    /// A host CLI can already hold the DeepSeek key used by its Anthropic/OpenAI
    /// compatibility route. Prefer that read-only credential, then fall back to
    /// TokenRemain's ordinary provider key sources.
    func fetch(apiKey: String?, now: Date = .now) async throws -> ProviderQuota {
        guard let key = normalized(apiKey) ?? ProviderSecretStore(provider: .deepseek).load() else {
            throw ExtendedProviderError.notConfigured(.deepseek)
        }
        let data = try await ExtendedHTTP.request(
            .deepseek,
            url: URL(string: "https://api.deepseek.com/user/balance")!,
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        )
        return try Self.parse(data, now: now)
    }

    private func normalized(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty ? nil : result
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data),
              let infos = body["balance_infos"] as? [[String: Any]] else {
            throw ExtendedProviderError.invalidResponse(.deepseek)
        }
        let available = body["is_available"] as? Bool ?? !infos.isEmpty
        // 优先取有余额的一行(通常是 CNY / USD 各一行)做主行。
        let rowIndex = infos.firstIndex { (ExtendedHTTP.number($0["total_balance"]) ?? 0) > 0 }
            ?? infos.indices.first
        let row = rowIndex.map { infos[$0] }
        let rawAmount = row.flatMap { ExtendedHTTP.number($0["total_balance"]) } ?? 0
        let amount = rawAmount.isFinite ? max(0, rawAmount) : 0
        let currency = (row?["currency"] as? String) ?? ""

        // 其余仍有余额的币种各成一条 scoped 余额行:主行只承载首个币种,
        // 另一币种也充了值时不再被静默吞掉。0.00 的占位行(几乎每个账户都
        // 带一条未充值币种)不出行,避免常驻一条"已用尽"噪音。
        // granted/topped_up 子池暂不拆(见修复方案 §11)。
        var scoped: [ScopedQuotaWindow] = []
        var seenScopeIDs: Set<String> = []
        for (index, info) in infos.enumerated() where index != rowIndex {
            let extraRaw = ExtendedHTTP.number(info["total_balance"]) ?? 0
            guard extraRaw.isFinite, extraRaw > 0 else { continue }
            let extraCurrency = ((info["currency"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let slug = extraCurrency.lowercased()
                .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            guard !slug.isEmpty else { continue }
            let scopeID = "deepseek_\(String(slug.prefix(23)))"
            guard seenScopeIDs.insert(scopeID).inserted else { continue }
            scoped.append(
                ScopedQuotaWindow(
                    scopeID: scopeID,
                    displayName: extraCurrency,
                    window: QuotaWindow(
                        // 与主行同口径:有可用余额即 0%,不可用即 100%。
                        usedPercent: available ? 0 : 100,
                        windowMinutes: 0,
                        resetsAt: nil,
                        remainingBalance: QuotaBalance(amount: extraRaw, currencyCode: extraCurrency)
                    ),
                    observedAt: now
                )
            )
        }
        return ProviderQuota(
            provider: .deepseek,
            primary: QuotaWindow(
                usedPercent: available && amount > 0 ? 0 : 100,
                windowMinutes: 0,
                resetsAt: nil,
                remainingBalance: QuotaBalance(amount: amount, currencyCode: currency)
            ),
            secondary: nil,
            // Keep the legacy sanitized label for older synced clients while
            // current quota rows consume the structured balance below.
            planName: L10n.format(
                "service.deepseek.balance_plan",
                currency == "CNY" ? "¥" : (currency == "USD" ? "$" : "\(currency) "),
                String(format: "%.2f", amount)
            ),
            capturedAt: now,
            scopedWindows: scoped.isEmpty ? nil : scoped,
            remainingBalance: QuotaBalance(amount: amount, currencyCode: currency)
        )
    }
}

// MARK: - Kimi(本地 CLI 凭证自动发现 + API Key 或 kimi-auth Cookie 值)

/// 取数顺序:① 路由来的显式凭证;② Kimi Code CLI 本地 access_token
/// (只读、留 60 秒余量,见 KimiLocalCredentialReader);③ 手动粘贴的
/// 钥匙串凭证。CLI token 固定走 Code API(Bearer),手动凭证维持原有
/// 双口径:Key 形态走 `GET api.kimi.com/coding/v1/usages`(Bearer);
/// JWT 形态按 kimi-auth 走 `POST www.kimi.com/apiv2 …BillingService/GetUsages`。
/// 响应 `limits[]` 每项:detail{used/limit/remaining/percent} +
/// window{duration,timeUnit},按窗口时长升序铺开:最短做 primary,
/// 时长不同的最长做 secondary,其余进 scoped,任何窗口不丢。
struct KimiUsageService {
    /// 测试注入:本地 CLI 凭证发现。
    var loadLocalCredential: (Date) -> KimiLocalCredential? = {
        KimiLocalCredentialReader().load(now: $0)
    }
    /// 测试注入:手动凭证读取。
    var loadManualSecret: () -> String? = { ProviderSecretStore(provider: .kimi).load() }
    /// 测试注入:HTTP 请求。
    var httpRequest: (URL, String, [String: String], Data?) async throws -> Data = {
        try await ExtendedHTTP.request(.kimi, url: $0, method: $1, headers: $2, body: $3)
    }

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(secret: nil, now: now)
    }

    func fetch(secret routedSecret: String?, now: Date = .now) async throws -> ProviderQuota {
        let cleaned = routedSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let routed = cleaned, !routed.isEmpty {
            return try await fetchManual(secret: routed, now: now)
        }
        let manual = loadManualSecret()
        // CLI 凭证优先于手动粘贴:CLI 会定期换新,手动 JWT 长期过期正是
        // 401 的主要来源;CLI token 意外被拒时仍回落手动流程。
        if let local = loadLocalCredential(now) {
            do {
                return try await fetchLocal(local, now: now)
            } catch {
                guard manual != nil else { throw error }
            }
        }
        guard let manual else {
            throw ExtendedProviderError.notConfigured(.kimi)
        }
        return try await fetchManual(secret: manual, now: now)
    }

    /// CLI access_token 一律走官方 Code API;它虽形如 JWT,但不是
    /// kimi-auth 网页会话,绝不能路由到 www.kimi.com/apiv2 口径。
    private func fetchLocal(_ credential: KimiLocalCredential, now: Date) async throws -> ProviderQuota {
        let data = try await httpRequest(
            KimiLocalCredentialReader.usageURL,
            "GET",
            KimiLocalCredentialReader.requestHeaders(for: credential),
            nil
        )
        return try Self.parse(data, now: now)
    }

    private func fetchManual(secret: String, now: Date) async throws -> ProviderQuota {
        let data: Data
        if secret.split(separator: ".").count == 3 {
            // kimi-auth 是 JWT:走网页端 Connect 接口,带官方前端同款头。
            var headers = [
                "Authorization": "Bearer \(secret)",
                "Cookie": "kimi-auth=\(secret)",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Origin": "https://www.kimi.com",
                "Referer": "https://www.kimi.com/code/console",
                "connect-protocol-version": "1",
                "x-msh-platform": "web"
            ]
            if let payload = JWT.payload(secret) {
                if let device = payload["device_id"] { headers["x-msh-device-id"] = "\(device)" }
                if let ssid = payload["ssid"] { headers["x-msh-session-id"] = "\(ssid)" }
                if let sub = payload["sub"] { headers["x-traffic-id"] = "\(sub)" }
            }
            data = try await httpRequest(
                URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!,
                "POST",
                headers,
                Data(#"{"scope": ["FEATURE_CODING"]}"#.utf8)
            )
        } else {
            data = try await httpRequest(
                URL(string: "https://api.kimi.com/coding/v1/usages")!,
                "GET",
                ["Authorization": "Bearer \(secret)", "Accept": "application/json"],
                nil
            )
        }
        return try Self.parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data) else {
            throw ExtendedProviderError.invalidResponse(.kimi)
        }
        let entries = (body["limits"] as? [[String: Any]])
            ?? ((body["data"] as? [String: Any])?["limits"] as? [[String: Any]])
            ?? []

        // limits[] 是开放数组,窗口数不定。全部解析后按时长升序稳定排序:
        // 最短档 → primary、与之时长不同的最长档 → secondary(时长必不同,
        // 手机同步安全),档内取最忙的池;其余(中间档、同时长兄弟)→
        // scoped,任何窗口不丢。
        var parsed: [(window: QuotaWindow, name: String?)] = []
        for entry in entries {
            let detail = (entry["detail"] as? [String: Any]) ?? entry
            guard let percent = usedPercent(detail) else { continue }
            let window = entry["window"] as? [String: Any]
            let minutes = windowMinutes(window) ?? 300
            let resetsAt = resetDate(detail["resetTime"] ?? detail["reset_time"] ?? window?["resetTime"])
            parsed.append((
                window: QuotaWindow(
                    usedPercent: ExtendedHTTP.clamp(percent),
                    windowMinutes: minutes,
                    resetsAt: resetsAt
                ),
                name: entryName(entry)
            ))
        }
        guard !parsed.isEmpty else {
            throw ExtendedProviderError.invalidResponse(.kimi)
        }
        let ordered = parsed.enumerated()
            .sorted { ($0.element.window.windowMinutes, $0.offset) < ($1.element.window.windowMinutes, $1.offset) }
            .map(\.element)
        // 被选中的时长档内取最忙的池(usedPercent 最高)——它才是瓶颈;
        // 响应顺序只做平手裁决(ordered 档内保持响应序,严格大于即先到先得)。
        func busiestIndex(minutes: Int) -> Int {
            var best = ordered.firstIndex { $0.window.windowMinutes == minutes }!
            for index in ordered.indices
            where ordered[index].window.windowMinutes == minutes
                && ordered[index].window.usedPercent > ordered[best].window.usedPercent {
                best = index
            }
            return best
        }
        func siblingCount(minutes: Int) -> Int {
            ordered.count { $0.window.windowMinutes == minutes }
        }
        let shortestMinutes = ordered.first!.window.windowMinutes
        let longestMinutes = ordered.last!.window.windowMinutes
        let primaryIndex = busiestIndex(minutes: shortestMinutes)
        let secondaryIndex: Int? =
            longestMinutes == shortestMinutes ? nil : busiestIndex(minutes: longestMinutes)
        // 时长档里有兄弟池时,被选中的窗口是命名池而非整账户,带上池名
        // (名字来源与 scoped 相同)与 scoped 兄弟行区分开。
        var primary = ordered[primaryIndex].window
        if siblingCount(minutes: shortestMinutes) > 1 {
            primary.poolName = ordered[primaryIndex].name
                ?? durationLabel(minutes: shortestMinutes)
        }
        var secondary = secondaryIndex.map { ordered[$0].window }
        if let secondaryIndex, siblingCount(minutes: longestMinutes) > 1 {
            secondary?.poolName = ordered[secondaryIndex].name
                ?? durationLabel(minutes: longestMinutes)
        }
        var scoped: [ScopedQuotaWindow] = []
        var seenScopeIDs: Set<String> = []
        for (index, item) in ordered.enumerated() where index != primaryIndex && index != secondaryIndex {
            let name = item.name ?? durationLabel(minutes: item.window.windowMinutes)
            var scopeID = "kimi_\(slug(name, maxLength: 25))"
            var deduplicate = 2
            while !seenScopeIDs.insert(scopeID).inserted {
                scopeID = "kimi_\(slug(name, maxLength: 25))_\(deduplicate)"
                deduplicate += 1
            }
            scoped.append(
                ScopedQuotaWindow(
                    scopeID: scopeID,
                    displayName: name,
                    window: item.window,
                    observedAt: now
                )
            )
        }
        return ProviderQuota(
            provider: .kimi,
            primary: primary,
            secondary: secondary,
            planName: nil,
            capturedAt: now,
            scopedWindows: scoped.isEmpty ? nil : scoped
        )
    }

    /// 条目自带的展示名;上游没给时由 `durationLabel` 按时长补一个语义词。
    private static func entryName(_ entry: [String: Any]) -> String? {
        let detail = (entry["detail"] as? [String: Any]) ?? [:]
        for source in [entry, detail] {
            for key in ["name", "title", "label", "displayName", "display_name"] {
                if let value = (source[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func durationLabel(minutes: Int) -> String {
        switch minutes {
        case 60: return "Hourly"
        case 300: return "Session"
        case 1_440: return "Daily"
        case 10_080: return "Weekly"
        case 43_200: return "Monthly"
        default: return "\(minutes) min"
        }
    }

    /// scopeID 需满足同步侧 `[a-z0-9_-]{1,32}` 的约束。
    private static func slug(_ name: String, maxLength: Int) -> String {
        let slug = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((slug.isEmpty ? "window" : slug).prefix(maxLength))
    }

    private static func usedPercent(_ detail: [String: Any]) -> Double? {
        let used = first(detail, ["used", "usedAmount", "used_amount", "usage"])
        let limit = first(detail, ["limit", "total", "quota", "amount"])
        if let used, let limit, limit > 0 { return used / limit * 100 }
        let remaining = first(detail, ["remaining", "left", "remain"])
        if let limit, limit > 0, let remaining { return (limit - remaining) / limit * 100 }
        return first(detail, ["percent", "usedPercent", "used_percent", "ratio", "usedRatio", "used_ratio"])
            .map { $0 <= 1 ? $0 * 100 : $0 }
    }

    private static func windowMinutes(_ window: [String: Any]?) -> Int? {
        guard let window,
              let duration = first(window, ["duration", "windowDuration", "window_duration", "size", "value"]) else {
            return nil
        }
        let unit = ((window["timeUnit"] ?? window["time_unit"] ?? window["unit"]) as? String)?.uppercased() ?? ""
        let perUnit: Double
        if unit.contains("MINUTE") { perUnit = 1 } else if unit.contains("HOUR") { perUnit = 60 } else if unit.contains("DAY") { perUnit = 1_440 } else if unit.contains("WEEK") { perUnit = 10_080 } else if unit.contains("SECOND") { perUnit = 1.0 / 60 } else { return nil }
        return Int(duration * perUnit)
    }

    private static func first(_ object: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let value = ExtendedHTTP.number(object[key]) { return value }
        }
        return nil
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let epoch = ExtendedHTTP.number(value), epoch > 0 {
            return Date(timeIntervalSince1970: epoch > 1e10 ? epoch / 1000 : epoch)
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - MiniMax(API Key,Coding Plan)

/// `GET api.minimax.io(/.cn) /v1/api/openplatform/coding_plan/remains`。
/// `data.model_remains[]` 里 `model_name == "general"` 的一行是编码计划:
/// `current_interval_remaining_percent`(5 小时,剩余)/ `end_time`(ms)、
/// `current_weekly_remaining_percent` / `weekly_end_time`。百分比可能是字符串。
struct MiniMaxUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(apiKey: nil, now: now)
    }

    func fetch(apiKey routedKey: String?, now: Date = .now) async throws -> ProviderQuota {
        let cleaned = routedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = (cleaned?.isEmpty == false ? cleaned : nil)
            ?? ProviderSecretStore(provider: .minimax).load() else {
            throw ExtendedProviderError.notConfigured(.minimax)
        }
        let hosts = ["https://api.minimax.io", "https://api.minimaxi.com"]
        var lastError: Error = ExtendedProviderError.invalidResponse(.minimax)
        for host in hosts {
            do {
                let data = try await ExtendedHTTP.request(
                    .minimax,
                    url: URL(string: "\(host)/v1/api/openplatform/coding_plan/remains")!,
                    headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"]
                )
                return try Self.parse(data, now: now)
            } catch {
                // 国际/国内双区:Key 属于另一区时以业务码或 4xx 拒绝,换区重试。
                lastError = error
            }
        }
        throw lastError
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data) else {
            throw ExtendedProviderError.invalidResponse(.minimax)
        }
        let rows = ((body["data"] as? [String: Any])?["model_remains"] as? [[String: Any]])
            ?? (body["model_remains"] as? [[String: Any]])
            ?? []
        guard let primaryIndex = rows.firstIndex(where: {
            ($0["model_name"] as? String)?.caseInsensitiveCompare("general") == .orderedSame
        }) ?? rows.indices.first else {
            throw ExtendedProviderError.invalidResponse(.minimax)
        }
        let row = rows[primaryIndex]

        func window(
            in source: [String: Any],
            _ percentKey: String,
            _ endKey: String,
            minutes: Int
        ) -> QuotaWindow? {
            guard let remaining = ExtendedHTTP.number(source[percentKey]) else { return nil }
            let resetsAt = ExtendedHTTP.number(source[endKey]).map { Date(timeIntervalSince1970: $0 / 1000) }
            return QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(100 - remaining),
                windowMinutes: minutes,
                resetsAt: resetsAt
            )
        }
        let session = window(in: row, "current_interval_remaining_percent", "end_time", minutes: 300)
        let weekly = window(in: row, "current_weekly_remaining_percent", "weekly_end_time", minutes: 10_080)
        guard let primary = session ?? weekly else {
            throw ExtendedProviderError.invalidResponse(.minimax)
        }
        var scopedWindows: [ScopedQuotaWindow] = []
        for (index, lane) in rows.enumerated() where index != primaryIndex {
            let rawName = ((lane["model_name"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty else { continue }
            let slug = rawName.lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            guard !slug.isEmpty else { continue }
            if let laneSession = window(
                in: lane,
                "current_interval_remaining_percent",
                "end_time",
                minutes: 300
            ) {
                scopedWindows.append(
                    ScopedQuotaWindow(
                        scopeID: "minimax_\(slug)_session",
                        displayName: rawName,
                        window: laneSession
                    )
                )
            }
            if let laneWeekly = window(
                in: lane,
                "current_weekly_remaining_percent",
                "weekly_end_time",
                minutes: 10_080
            ) {
                scopedWindows.append(
                    ScopedQuotaWindow(
                        scopeID: "minimax_\(slug)_weekly",
                        displayName: rawName,
                        window: laneWeekly
                    )
                )
            }
        }
        return ProviderQuota(
            provider: .minimax,
            primary: primary,
            secondary: session == nil ? nil : weekly,
            planName: "Coding Plan",
            capturedAt: now,
            scopedWindows: scopedWindows.isEmpty ? nil : scopedWindows
        )
    }
}

// MARK: - MiMo Code(Cookie,钱包余额 + Token Plan)

/// MiMo 控制台把钱包和 Token Plan 拆在不同接口。余额是必须成功的
/// 基线；用户资料、套餐详情和套餐用量均为尽力读取，避免其中一个可选
/// 接口短暂波动时把仍然有效的钱包余额一起丢掉。钱包一律挂
/// `accountBalance`,不再充当 secondary 窗口;套餐的日维度 day_token
/// 以 scoped "Daily" 行展示。
struct MiMoUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(cookie: nil, now: now)
    }

    func fetch(cookie routedCookie: String?, now: Date = .now) async throws -> ProviderQuota {
        guard let rawCookie = routedCookie ?? ProviderSecretStore(provider: .mimo).load() else {
            throw ExtendedProviderError.notConfigured(.mimo)
        }
        guard let cookie = Self.normalizedCookie(rawCookie) else {
            throw ExtendedProviderError.invalidSecret(
                .mimo,
                detail: L10n.text("service.mimo.cookie_incomplete")
            )
        }
        let base = "https://platform.xiaomimimo.com/api/v1"
        let headers = [
            "Cookie": cookie,
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://platform.xiaomimimo.com",
            "Referer": "https://platform.xiaomimimo.com/#/console/balance"
        ]
        async let balanceAttempt = ExtendedHTTP.request(
            .mimo,
            url: URL(string: "\(base)/balance")!,
            headers: headers,
            followRedirects: false
        )
        async let detailAttempt = try? ExtendedHTTP.request(
            .mimo,
            url: URL(string: "\(base)/tokenPlan/detail")!,
            headers: headers,
            followRedirects: false
        )
        async let usageAttempt = try? ExtendedHTTP.request(
            .mimo,
            url: URL(string: "\(base)/tokenPlan/usage")!,
            headers: headers,
            followRedirects: false
        )
        let balanceData = try await balanceAttempt
        try Self.validateBusinessResponse(balanceData)
        return try await Self.parse(
            balanceData: balanceData,
            detailData: detailAttempt,
            usageData: usageAttempt,
            now: now
        )
    }

    static func normalizedCookie(_ raw: String) -> String? {
        let allowed = Set([
            "api-platform_serviceToken", "userId", "api-platform_ph", "api-platform_slh"
        ])
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count))
        }
        var values: [String: String] = [:]
        for component in text.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if allowed.contains(name), !value.isEmpty { values[name] = value }
        }
        guard values["api-platform_serviceToken"] != nil, values["userId"] != nil else {
            return nil
        }
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    }

    private static func validateBusinessResponse(_ data: Data) throws {
        guard let body = ExtendedHTTP.json(data) else {
            throw ExtendedProviderError.invalidResponse(.mimo)
        }
        guard let code = ExtendedHTTP.number(body["code"]) else { return }
        if code == 401 || code == 403 {
            throw ExtendedProviderError.secretRejected(.mimo, Int(code))
        }
        if code != 0 {
            throw ExtendedProviderError.invalidResponse(.mimo)
        }
    }

    /// Legacy single-payload entry point retained for older fixtures. It
    /// accepts either the old embedded month_total_token shape or a wallet
    /// balance response.
    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data) else {
            throw ExtendedProviderError.invalidResponse(.mimo)
        }
        if balance(in: body) != nil {
            return try parse(balanceData: data, now: now)
        }
        guard let usage = planUsage(in: body), let percent = usage.usedPercent else {
            throw ExtendedProviderError.invalidResponse(.mimo)
        }
        return ProviderQuota(
            provider: .mimo,
            primary: QuotaWindow(
                usedPercent: percent,
                windowMinutes: 43_200,
                resetsAt: nil
            ),
            secondary: nil,
            planName: nil,
            capturedAt: now,
            scopedWindows: dayScopedWindows(in: body, now: now)
        )
    }

    static func parse(
        balanceData: Data,
        detailData: Data? = nil,
        usageData: Data? = nil,
        now: Date = .now
    ) throws -> ProviderQuota {
        guard let balanceBody = ExtendedHTTP.json(balanceData),
              let wallet = balance(in: balanceBody) else {
            throw ExtendedProviderError.invalidResponse(.mimo)
        }
        let detail = detailData.flatMap(ExtendedHTTP.json).map { planDetail(in: $0, now: now) }
        let usageBody = usageData.flatMap(ExtendedHTTP.json)
        let usage = usageBody.flatMap(planUsage)
        let hasPlan = detail?.isActive == true
            && (usage?.limit ?? 0) > 0
            && usage?.usedPercent != nil

        let walletBalance = QuotaBalance(
            amount: wallet.amount,
            currencyCode: wallet.currency
        )
        // 无套餐时钱包仍需一个占位主窗口(有/无余额的可用性),但有套餐时
        // 钱包只挂 accountBalance,不再做 secondary——0 分钟的空钱包窗口会在
        // lowestRemaining 策略下劫持菜单栏显示 0%。
        let walletWindow = QuotaWindow(
            usedPercent: wallet.amount > 0 ? 0 : 100,
            windowMinutes: 0,
            resetsAt: nil,
            remainingBalance: walletBalance
        )
        let planWindow = hasPlan ? QuotaWindow(
            usedPercent: usage?.usedPercent ?? 0,
            windowMinutes: 43_200,
            resetsAt: detail?.resetsAt
        ) : nil
        // day_token 是套餐的日维度,只有套餐在用时才有意义。
        let dayScoped = hasPlan ? usageBody.flatMap { dayScopedWindows(in: $0, now: now) } : nil

        return ProviderQuota(
            provider: .mimo,
            primary: planWindow ?? walletWindow,
            secondary: nil,
            planName: detail?.label.isEmpty == false ? detail?.label : nil,
            capturedAt: now,
            accountBalance: walletBalance,
            scopedWindows: dayScoped,
            remainingBalance: planWindow == nil ? walletBalance : nil
        )
    }

    private struct WalletBalance {
        let amount: Double
        let currency: String
    }

    private struct PlanDetail {
        let label: String
        let resetsAt: Date?
        let isActive: Bool
    }

    private struct PlanUsage {
        let used: Double?
        let limit: Double?
        let usedPercent: Double?
    }

    private static func unwrapped(_ body: [String: Any]) -> [String: Any] {
        (body["data"] as? [String: Any]) ?? body
    }

    private static func balance(in body: [String: Any]) -> WalletBalance? {
        let payload = unwrapped(body)
        guard let rawAmount = ExtendedHTTP.number(payload["balance"]), rawAmount.isFinite else {
            return nil
        }
        let currency = ((payload["currency"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return WalletBalance(amount: max(0, rawAmount), currency: currency)
    }

    private static func planDetail(in body: [String: Any], now: Date) -> PlanDetail {
        let payload = unwrapped(body)
        let label = firstText(
            payload,
            keys: ["planCode", "plan_code", "planName", "plan_name"]
        )
        let status = firstText(
            payload,
            keys: ["planStatus", "plan_status", "subscriptionStatus", "subscription_status", "status", "state"]
        ).lowercased()
        let resetsAt = firstText(
            payload,
            keys: ["currentPeriodEnd", "current_period_end"]
        ).nilIfEmpty.flatMap(parseDate)
        let noPlan = ["default", "none", "no_plan", "not_subscribed", "unsubscribed"]
            .contains(label.lowercased().replacingOccurrences(of: "-", with: "_"))
        let expired = ["expired", "ended"].contains(status)
            || (resetsAt.map { $0 <= now } == true)
        let hasExplicitActiveFlag = payload["active"] is Bool || payload["isActive"] is Bool
        let explicitActive = ["active", "subscribed"].contains(status)
            || payload["active"] as? Bool == true
            || payload["isActive"] as? Bool == true
        let inferredActive = status.isEmpty && !hasExplicitActiveFlag
            && !label.isEmpty && resetsAt.map { $0 > now } == true
        return PlanDetail(
            label: label,
            resetsAt: resetsAt,
            isActive: !noPlan && !expired && (explicitActive || inferredActive)
        )
    }

    private static func planUsage(in body: [String: Any]) -> PlanUsage? {
        let month = usageContainer(in: body)
        let item: [String: Any]
        if let items = month["items"] as? [[String: Any]], !items.isEmpty {
            guard let total = items.first(where: {
                ($0["name"] as? String)?.lowercased() == "month_total_token"
            }) else {
                return nil
            }
            item = total
        } else {
            item = findItem(named: "month_total_token", in: month) ?? month
        }
        return usageMetric(from: item)
    }

    /// monthUsage.items[] 里的 `day_token` 是套餐的日维度:当天耗尽时月度
    /// 百分比可能还很低,不端出来会误导。做成 scoped "Daily" 行,重置时间
    /// 优先上游字段,否则按北京时区(MiMo 是国内平台)当日边界推算。
    private static func dayScopedWindows(in body: [String: Any], now: Date) -> [ScopedQuotaWindow]? {
        let container = usageContainer(in: body)
        let item: [String: Any]?
        if let items = container["items"] as? [[String: Any]], !items.isEmpty {
            item = items.first { ($0["name"] as? String)?.lowercased() == "day_token" }
        } else {
            item = findItem(named: "day_token", in: container)
        }
        guard let item,
              let usage = usageMetric(from: item),
              let percent = usage.usedPercent else {
            return nil
        }
        return [
            ScopedQuotaWindow(
                scopeID: "mimo_daily",
                displayName: "Daily",
                window: QuotaWindow(
                    usedPercent: percent,
                    windowMinutes: 1_440,
                    resetsAt: dayResetDate(item: item, now: now)
                ),
                observedAt: now
            )
        ]
    }

    private static func usageContainer(in body: [String: Any]) -> [String: Any] {
        let payload = unwrapped(body)
        return (payload["monthUsage"] as? [String: Any])
            ?? (payload["month_usage"] as? [String: Any])
            ?? payload
    }

    private static func usageMetric(from item: [String: Any]) -> PlanUsage? {
        let used = ExtendedHTTP.number(item["used"])
        let limit = ExtendedHTTP.number(item["limit"])
            ?? ExtendedHTTP.number(item["total"])
        let percent: Double?
        if let used, let limit, limit > 0 {
            percent = ExtendedHTTP.clamp(used / limit * 100)
        } else if let ratio = ExtendedHTTP.number(item["percent"]), ratio.isFinite {
            // MiMo's percent field is always a 0…1 ratio and can exceed 1
            // slightly after the request that exhausts a plan.
            percent = ExtendedHTTP.clamp(ratio * 100)
        } else {
            percent = nil
        }
        guard used != nil || limit != nil || percent != nil else { return nil }
        return PlanUsage(used: used, limit: limit, usedPercent: percent)
    }

    private static func dayResetDate(item: [String: Any], now: Date) -> Date? {
        for key in ["resetTime", "reset_time", "resetAt", "reset_at", "endTime", "end_time"] {
            if let epoch = ExtendedHTTP.number(item[key]), epoch > 0 {
                return Date(timeIntervalSince1970: epoch > 1e10 ? epoch / 1000 : epoch)
            }
            if let text = item[key] as? String, let date = parseDate(text) {
                return date
            }
        }
        guard let timeZone = TimeZone(identifier: "Asia/Shanghai") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }

    private static func firstText(_ body: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = body[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    private static func parseDate(_ raw: String) -> Date? {
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let utcFractional = ISO8601DateFormatter()
        utcFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: normalized)
            ?? ISO8601DateFormatter().date(from: normalized)
            ?? utcFractional.date(from: "\(normalized)Z")
            ?? ISO8601DateFormatter().date(from: "\(normalized)Z")
    }

    /// 容器结构历史上变过,递归找 `name == <目标>` 的对象
    /// (month_total_token / day_token 共用)。
    private static func findItem(named target: String, in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if (object["name"] as? String)?.lowercased() == target { return object }
            for child in object.values {
                if let found = findItem(named: target, in: child) { return found }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = findItem(named: target, in: child) { return found }
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// Qoder(本地 IPC 优先 + Cookie 兜底)移至 QoderUsageService.swift。

// MARK: - Kiro(CLI 子进程)

/// Kiro 无用量 API:运行 `kiro-cli chat --no-interactive /usage`,
/// 剥离 ANSI 后正则取 Credits 百分比与重置日(与 CodexBar/token-monitor 同口径)。
struct KiroUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let cli = Self.cliPath() else {
            throw ExtendedProviderError.notInstalled(.kiro, hint: L10n.text("service.kiro.not_installed"))
        }
        let output = try await ProcessRunner.run(cli, arguments: ["chat", "--no-interactive", "/usage"])
        return try Self.parse(String(data: output, encoding: .utf8) ?? "", now: now)
    }

    static func cliPath(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        var candidates = [
            home.appending(path: ".local/bin/kiro-cli").path,
            "/opt/homebrew/bin/kiro-cli",
            "/usr/local/bin/kiro-cli"
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/kiro-cli" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func parse(_ rawOutput: String, now: Date = .now) throws -> ProviderQuota {
        let stripped = rawOutput.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        var percent: Double?
        // 进度条空段可能以空格或 ░ 渲染,两种都接受。
        if let match = stripped.range(of: #"█+[░\s]*(\d+)%"#, options: .regularExpression) {
            percent = Double(stripped[match].filter(\.isNumber))
        }
        if percent == nil,
           let match = stripped.range(of: #"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered"#, options: .regularExpression) {
            let numbers = stripped[match]
                .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap(Double.init)
            if numbers.count >= 2, numbers[1] > 0 {
                percent = numbers[0] / numbers[1] * 100
            }
        }
        guard let percent else {
            throw ExtendedProviderError.invalidResponse(.kiro)
        }

        var resetsAt: Date?
        if let match = stripped.range(of: #"resets on (\d{4}-\d{2}-\d{2})"#, options: .regularExpression) {
            let dateText = String(stripped[match].suffix(10))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            resetsAt = formatter.date(from: dateText)
        }
        return ProviderQuota(
            provider: .kiro,
            primary: QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(percent),
                windowMinutes: 43_200,
                resetsAt: resetsAt
            ),
            secondary: nil,
            planName: nil,
            capturedAt: now
        )
    }
}

// MARK: - Volcengine(AK:SK 签名,Coding Plan)

/// `POST open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01`,
/// 火山 HMAC-SHA256 签名(service=ark)。响应 `Result` 内取 Percent。
struct VolcengineUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(credentials: nil, now: now)
    }

    func fetch(credentials routedCredentials: String?, now: Date = .now) async throws -> ProviderQuota {
        guard let combined = routedCredentials ?? ProviderSecretStore(provider: .volcengine).load() else {
            throw ExtendedProviderError.notConfigured(.volcengine)
        }
        let parts = combined.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw ExtendedProviderError.notInstalled(
                .volcengine,
                hint: L10n.text("service.volcengine.bad_credentials")
            )
        }
        let url = URL(string: "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")!
        let headers = Self.signedHeaders(
            accessKeyId: parts[0], secretAccessKey: parts[1],
            url: url, body: "", date: now
        )
        let data = try await ExtendedHTTP.request(.volcengine, url: url, method: "POST", headers: headers, body: Data())
        return try Self.parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data),
              let result = (body["Result"] ?? body["result"]) as? [String: Any],
              let percent = findPercent(in: result) else {
            throw ExtendedProviderError.invalidResponse(.volcengine)
        }
        return ProviderQuota(
            provider: .volcengine,
            primary: QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(percent),
                windowMinutes: 300,
                resetsAt: nil
            ),
            secondary: nil,
            planName: "Coding Plan",
            capturedAt: now
        )
    }

    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "VolcengineUsage")

    /// Percent 的定位必须确定:优先官方形状 `Result.user_limit.Percent`;
    /// 显式路径缺席才退化为递归查找,且遍历按 key 排序——Dictionary 的
    /// 原生遍历顺序跨启动随机,多池响应会今天显示 A 明天显示 B。
    /// 同时发现多个 Percent 时记 info 日志留证,取排序后的第一个。
    private static func findPercent(in result: [String: Any]) -> Double? {
        for key in ["user_limit", "UserLimit", "userLimit"] {
            if let limit = result[key] as? [String: Any],
               let percent = ExtendedHTTP.number(limit["Percent"] ?? limit["percent"]) {
                return percent
            }
        }
        let matches = percentMatches(in: result, path: "Result")
        if matches.count > 1 {
            let paths = matches.map(\.path).joined(separator: ", ")
            logger.info("Volcengine response carries \(matches.count) Percent fields (\(paths, privacy: .public)); using \(matches[0].path, privacy: .public)")
        }
        return matches.first?.percent
    }

    /// 深度优先收集所有 Percent,子键按字典序遍历保证结果确定。
    /// 对象自身带 Percent 时即为该子树的答案,不再继续下钻。
    private static func percentMatches(in value: Any, path: String) -> [(path: String, percent: Double)] {
        if let object = value as? [String: Any] {
            if let percent = ExtendedHTTP.number(object["Percent"] ?? object["percent"]) {
                return [(path, percent)]
            }
            return object.keys.sorted().flatMap { key in
                percentMatches(in: object[key]!, path: "\(path).\(key)")
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, child in
                percentMatches(in: child, path: "\(path)[\(index)]")
            }
        }
        return []
    }

    /// 火山引擎 V4 式签名(HMAC-SHA256,service=ark,region=cn-beijing)。
    static func signedHeaders(
        accessKeyId: String,
        secretAccessKey: String,
        url: URL,
        body: String,
        date: Date,
        region: String = "cn-beijing"
    ) -> [String: String] {
        let service = "ark"
        let signedHeaderNames = "content-type;host;x-content-sha256;x-date"
        let contentType = "application/x-www-form-urlencoded; charset=utf-8"

        let utc = TimeZone(secondsFromGMT: 0)!
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.timeZone = utc
        stampFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = stampFormatter.string(from: date)
        let dateStamp = String(timestamp.prefix(8))

        let payloadHash = sha256Hex(Data(body.utf8))
        let host = url.host ?? ""
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.~"))) ?? $0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            "POST",
            url.path.isEmpty ? "/" : url.path,
            query,
            "content-type:\(contentType)",
            "host:\(host)",
            "x-content-sha256:\(payloadHash)",
            "x-date:\(timestamp)",
            "",
            signedHeaderNames,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/request"
        let stringToSign = ["HMAC-SHA256", timestamp, scope, sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")

        let dateKey = hmac(Data(secretAccessKey.utf8), dateStamp)
        let regionKey = hmac(dateKey, region)
        let serviceKey = hmac(regionKey, service)
        let signingKey = hmac(serviceKey, "request")
        let signature = hmac(signingKey, stringToSign).map { String(format: "%02x", $0) }.joined()

        return [
            "Accept": "application/json",
            "Content-Type": contentType,
            "X-Date": timestamp,
            "X-Content-Sha256": payloadHash,
            "Authorization": "HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signedHeaderNames), Signature=\(signature)"
        ]
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
}

// MARK: - Ollama(session Cookie,设置页解析)

/// Ollama 无用量 API:带登录 Cookie 抓 `ollama.com/settings`,从 HTML 里
/// 解析 "Session/Hourly/Weekly usage … N% used"。签出状态如实提示。
struct OllamaUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(cookie: nil, now: now)
    }

    func fetch(cookie routedCookie: String?, now: Date = .now) async throws -> ProviderQuota {
        guard let cookie = routedCookie ?? ProviderSecretStore(provider: .ollama).load() else {
            throw ExtendedProviderError.notConfigured(.ollama)
        }
        let data = try await ExtendedHTTP.request(
            .ollama,
            url: URL(string: "https://ollama.com/settings")!,
            headers: [
                "Cookie": cookie,
                "Accept": "text/html,application/xhtml+xml"
            ]
        )
        return try Self.parse(String(data: data, encoding: .utf8) ?? "", now: now)
    }

    static func parse(_ html: String, now: Date = .now) throws -> ProviderQuota {
        let lower = html.lowercased()
        if lower.contains("sign in") && !lower.contains("usage") {
            throw ExtendedProviderError.secretRejected(.ollama, 401)
        }

        // 三个标签各归各槽,HTML 顺序不影响结果:Session(300)→ primary、
        // Weekly(10080)→ secondary、Hourly(60)→ scoped(不再与 Session
        // 抢主槽)。命名与 ollama.com 设置页的三个标签逐字一致。
        var session: QuotaWindow?
        var hourly: QuotaWindow?
        var weekly: QuotaWindow?
        let pattern = #"(Session usage|Hourly usage|Weekly usage)[\s\S]{0,400}?([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw ExtendedProviderError.invalidResponse(.ollama)
        }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let labelRange = Range(match.range(at: 1), in: html),
                  let percentRange = Range(match.range(at: 2), in: html),
                  let percent = Double(html[percentRange]) else { continue }
            let label = html[labelRange].lowercased()
            let window = QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(percent),
                windowMinutes: label.hasPrefix("weekly") ? 10_080 : (label.hasPrefix("hourly") ? 60 : 300),
                resetsAt: nil
            )
            if label.hasPrefix("weekly") {
                if weekly == nil { weekly = window }
            } else if label.hasPrefix("hourly") {
                if hourly == nil { hourly = window }
            } else if session == nil {
                session = window
            }
        }
        // Session/Weekly 双缺时 Hourly 顶上主槽,保住"有数据不报错"。
        guard let primary = session ?? weekly ?? hourly else {
            throw ExtendedProviderError.invalidResponse(.ollama)
        }
        let hourlyIsPrimary = session == nil && weekly == nil
        let scoped: [ScopedQuotaWindow]? = hourly.flatMap { window in
            hourlyIsPrimary ? nil : [
                ScopedQuotaWindow(
                    scopeID: "ollama_hourly",
                    displayName: "Hourly",
                    window: window,
                    observedAt: now
                )
            ]
        }
        return ProviderQuota(
            provider: .ollama,
            primary: primary,
            secondary: session == nil ? nil : weekly,
            planName: nil,
            capturedAt: now,
            scopedWindows: scoped
        )
    }
}
