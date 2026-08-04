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
        guard let key = ProviderSecretStore(provider: .deepseek).load() else {
            throw ExtendedProviderError.notConfigured(.deepseek)
        }
        let data = try await ExtendedHTTP.request(
            .deepseek,
            url: URL(string: "https://api.deepseek.com/user/balance")!,
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        )
        return try Self.parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data),
              let infos = body["balance_infos"] as? [[String: Any]] else {
            throw ExtendedProviderError.invalidResponse(.deepseek)
        }
        let available = body["is_available"] as? Bool ?? !infos.isEmpty
        // 优先取有余额的一行(通常是 CNY / USD 各一行)。
        let row = infos.first { (ExtendedHTTP.number($0["total_balance"]) ?? 0) > 0 } ?? infos.first
        let rawAmount = row.flatMap { ExtendedHTTP.number($0["total_balance"]) } ?? 0
        let amount = rawAmount.isFinite ? max(0, rawAmount) : 0
        let currency = (row?["currency"] as? String) ?? ""
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
            remainingBalance: QuotaBalance(amount: amount, currencyCode: currency)
        )
    }
}

// MARK: - Kimi(API Key 或 kimi-auth Cookie 值)

/// Key 形态走 `GET api.kimi.com/coding/v1/usages`(Bearer);JWT 形态按
/// kimi-auth 走 `POST www.kimi.com/apiv2 …BillingService/GetUsages`。
/// 响应 `limits[]` 每项:detail{used/limit/remaining/percent} +
/// window{duration,timeUnit},按窗口时长分会话/周。
struct KimiUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let secret = ProviderSecretStore(provider: .kimi).load() else {
            throw ExtendedProviderError.notConfigured(.kimi)
        }
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
            data = try await ExtendedHTTP.request(
                .kimi,
                url: URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!,
                method: "POST",
                headers: headers,
                body: Data(#"{"scope": ["FEATURE_CODING"]}"#.utf8)
            )
        } else {
            data = try await ExtendedHTTP.request(
                .kimi,
                url: URL(string: "https://api.kimi.com/coding/v1/usages")!,
                headers: ["Authorization": "Bearer \(secret)", "Accept": "application/json"]
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

        var session: QuotaWindow?
        var weekly: QuotaWindow?
        for entry in entries {
            let detail = (entry["detail"] as? [String: Any]) ?? entry
            guard let percent = usedPercent(detail) else { continue }
            let window = entry["window"] as? [String: Any]
            let minutes = windowMinutes(window) ?? 300
            let resetsAt = resetDate(detail["resetTime"] ?? detail["reset_time"] ?? window?["resetTime"])
            let quotaWindow = QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(percent),
                windowMinutes: minutes,
                resetsAt: resetsAt
            )
            if minutes < 1_440 {
                if session == nil { session = quotaWindow }
            } else if weekly == nil {
                weekly = quotaWindow
            }
        }
        guard let primary = session ?? weekly else {
            throw ExtendedProviderError.invalidResponse(.kimi)
        }
        return ProviderQuota(
            provider: .kimi,
            primary: primary,
            secondary: session == nil ? nil : weekly,
            planName: nil,
            capturedAt: now
        )
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
        guard let key = ProviderSecretStore(provider: .minimax).load() else {
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
        guard let row = rows.first(where: { ($0["model_name"] as? String) == "general" }) ?? rows.first else {
            throw ExtendedProviderError.invalidResponse(.minimax)
        }

        func window(_ percentKey: String, _ endKey: String, minutes: Int) -> QuotaWindow? {
            guard let remaining = ExtendedHTTP.number(row[percentKey]) else { return nil }
            let resetsAt = ExtendedHTTP.number(row[endKey]).map { Date(timeIntervalSince1970: $0 / 1000) }
            return QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(100 - remaining),
                windowMinutes: minutes,
                resetsAt: resetsAt
            )
        }
        let session = window("current_interval_remaining_percent", "end_time", minutes: 300)
        let weekly = window("current_weekly_remaining_percent", "weekly_end_time", minutes: 10_080)
        guard let primary = session ?? weekly else {
            throw ExtendedProviderError.invalidResponse(.minimax)
        }
        return ProviderQuota(
            provider: .minimax,
            primary: primary,
            secondary: session == nil ? nil : weekly,
            planName: "Coding Plan",
            capturedAt: now
        )
    }
}

// MARK: - MiMo Code(Cookie,钱包余额 + Token Plan)

/// MiMo 控制台把钱包和 Token Plan 拆在不同接口。余额是必须成功的
/// 基线；用户资料、套餐详情和套餐用量均为尽力读取，避免其中一个可选
/// 接口短暂波动时把仍然有效的钱包余额一起丢掉。
struct MiMoUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let rawCookie = ProviderSecretStore(provider: .mimo).load() else {
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
            capturedAt: now
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
        let usage = usageData.flatMap(ExtendedHTTP.json).flatMap(planUsage)
        let hasPlan = detail?.isActive == true
            && (usage?.limit ?? 0) > 0
            && usage?.usedPercent != nil

        let walletWindow = QuotaWindow(
            usedPercent: wallet.amount > 0 ? 0 : 100,
            windowMinutes: 0,
            resetsAt: nil,
            remainingBalance: QuotaBalance(
                amount: wallet.amount,
                currencyCode: wallet.currency
            )
        )
        let planWindow = hasPlan ? QuotaWindow(
            usedPercent: usage?.usedPercent ?? 0,
            windowMinutes: 43_200,
            resetsAt: detail?.resetsAt
        ) : nil

        return ProviderQuota(
            provider: .mimo,
            primary: planWindow ?? walletWindow,
            secondary: planWindow == nil ? nil : walletWindow,
            planName: detail?.label.isEmpty == false ? detail?.label : nil,
            capturedAt: now,
            remainingBalance: planWindow == nil ? walletWindow.remainingBalance : nil
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
        let payload = unwrapped(body)
        let month = (payload["monthUsage"] as? [String: Any])
            ?? (payload["month_usage"] as? [String: Any])
            ?? payload
        let item: [String: Any]
        if let items = month["items"] as? [[String: Any]], !items.isEmpty {
            guard let total = items.first(where: {
                ($0["name"] as? String)?.lowercased() == "month_total_token"
            }) else {
                return nil
            }
            item = total
        } else {
            item = findMonthTotal(in: month) ?? month
        }
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

    /// 容器结构历史上变过,递归找 `name == month_total_token` 的对象。
    private static func findMonthTotal(in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if (object["name"] as? String)?.lowercased() == "month_total_token" { return object }
            for child in object.values {
                if let found = findMonthTotal(in: child) { return found }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = findMonthTotal(in: child) { return found }
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Qoder(Cookie,Credits)

/// `GET qoder.com/api/v2/me/usages/big_model_credits`(Cookie)。
/// `totalQuota.quotaSummary{usedValue,limitValue}`(+可选 sharedQuota)
/// 合并为月度 Credits 百分比。
struct QoderUsageService {
    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let cookie = ProviderSecretStore(provider: .qoder).load() else {
            throw ExtendedProviderError.notConfigured(.qoder)
        }
        let data = try await ExtendedHTTP.request(
            .qoder,
            url: URL(string: "https://qoder.com/api/v2/me/usages/big_model_credits")!,
            headers: ["Cookie": cookie, "Accept": "application/json"]
        )
        return try Self.parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let body = ExtendedHTTP.json(data) else {
            throw ExtendedProviderError.invalidResponse(.qoder)
        }
        let payload = (body["data"] as? [String: Any]) ?? body
        func summary(_ key: String, _ snakeKey: String) -> (used: Double, total: Double)? {
            guard let container = (payload[key] ?? payload[snakeKey]) as? [String: Any],
                  let quotaSummary = (container["quotaSummary"] ?? container["quota_summary"]) as? [String: Any],
                  let used = ExtendedHTTP.number(quotaSummary["usedValue"] ?? quotaSummary["used_value"]),
                  let total = ExtendedHTTP.number(quotaSummary["limitValue"] ?? quotaSummary["limit_value"]),
                  used >= 0, total >= 0 else {
                return nil
            }
            return (used, total)
        }
        guard let total = summary("totalQuota", "total_quota") else {
            throw ExtendedProviderError.invalidResponse(.qoder)
        }
        let shared = summary("sharedQuota", "shared_quota")
        let usedCredits = total.used + (shared?.used ?? 0)
        let totalCredits = total.total + (shared?.total ?? 0)
        guard totalCredits > 0 else { throw ExtendedProviderError.invalidResponse(.qoder) }
        return ProviderQuota(
            provider: .qoder,
            primary: QuotaWindow(
                usedPercent: ExtendedHTTP.clamp(usedCredits / totalCredits * 100),
                windowMinutes: 43_200,
                resetsAt: nil
            ),
            secondary: nil,
            planName: nil,
            capturedAt: now
        )
    }
}

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
        guard let combined = ProviderSecretStore(provider: .volcengine).load() else {
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

    private static func findPercent(in value: Any) -> Double? {
        if let object = value as? [String: Any] {
            if let percent = ExtendedHTTP.number(object["Percent"] ?? object["percent"]) { return percent }
            for child in object.values {
                if let found = findPercent(in: child) { return found }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = findPercent(in: child) { return found }
            }
        }
        return nil
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
        guard let cookie = ProviderSecretStore(provider: .ollama).load() else {
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

        var session: QuotaWindow?
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
            } else if session == nil {
                session = window
            }
        }
        guard let primary = session ?? weekly else {
            throw ExtendedProviderError.invalidResponse(.ollama)
        }
        return ProviderQuota(
            provider: .ollama,
            primary: primary,
            secondary: session == nil ? nil : weekly,
            planName: nil,
            capturedAt: now
        )
    }
}
