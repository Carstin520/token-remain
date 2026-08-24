import Foundation
import OSLog

/// Grok(xAI)共享额度池直查。参考 OpenUsage(MIT)的 Grok provider,
/// 坚持只读:读取 Grok CLI 已有的凭证(`~/.grok/auth.json`),调用 CLI
/// 自己也在用的 billing 接口;**绝不代刷 refresh token**。token 过期时
/// 抛 `staleLogin`,提示用户运行一次 `grok` 恢复。
struct GrokUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case notLoggedIn
        case staleLogin
        case requestFailed(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return L10n.text("service.grok.not_logged_in")
            case .staleLogin:
                return L10n.text("service.grok.stale_login")
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed", "Grok", status)
            case .invalidResponse:
                return L10n.format("service.common.invalid_response", "Grok")
            }
        }
    }

    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "GrokUsage")

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(token: nil, now: now)
    }

    func fetch(token routedToken: String?, now: Date = .now) async throws -> ProviderQuota {
        let cleaned = routedToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth: GrokAuthReader.Auth?
        if let cleaned, !cleaned.isEmpty {
            auth = GrokAuthReader.Auth(token: cleaned, expiry: JWT.expiry(cleaned))
        } else {
            auth = GrokAuthReader().load()
        }
        guard let auth else {
            throw ServiceError.notLoggedIn
        }
        if let expiry = auth.expiry, expiry <= now {
            throw ServiceError.staleLogin
        }

        let (data, http) = try await Self.get(Self.creditsURL, token: auth.token)
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ServiceError.staleLogin
        default:
            throw ServiceError.requestFailed(http.statusCode)
        }

        // 计划名走 /v1/settings,尽力而为:失败不影响额度本身。
        var planName: String?
        if let (settingsData, settingsHTTP) = try? await Self.get(Self.settingsURL, token: auth.token),
           (200..<300).contains(settingsHTTP.statusCode) {
            planName = GrokUsageParser.planName(settingsData)
        }

        let quota = try GrokUsageParser.parse(data, planName: planName, now: now)
        Self.logger.info("Grok quota served by billing API")
        return quota
    }

    private static func get(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // billing 接口按 Grok CLI 的形态放行,需要它的标识头。
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        return (data, http)
    }
}

/// `billing?format=credits` 响应 → ProviderQuota。响应是 proto-JSON:
/// `config.creditUsagePercent`(零值时整个字段缺席,缺席 = 0%),
/// `config.currentPeriod {type, start, end}`(ISO8601)。窗口长度取真实
/// 账期跨度,周池即 7 天;旧月度账户如实显示月窗口。
enum GrokUsageParser {
    static func parse(_ data: Data, planName: String? = nil, now: Date = .now) throws -> ProviderQuota {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let config = root["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let start = isoDate(period["start"]),
              let end = isoDate(period["end"]),
              end > start else {
            throw GrokUsageService.ServiceError.invalidResponse
        }

        let usedPercent: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = number(raw), number.isFinite else {
                throw GrokUsageService.ServiceError.invalidResponse
            }
            usedPercent = number
        } else {
            // proto-JSON 会丢弃零值字段:缺席就是真实的 0%。
            usedPercent = 0
        }

        // 按量付费(on-demand)只有上限没有已花费字段(取证见
        // onDemandCapCredits 的注释),extraUsage 保持 nil,不臆造 0。
        return ProviderQuota(
            provider: .grok,
            primary: QuotaWindow(
                usedPercent: min(100, max(0, usedPercent)),
                windowMinutes: max(1, Int(end.timeIntervalSince(start) / 60)),
                resetsAt: end
            ),
            secondary: nil,
            planName: planName,
            capturedAt: now
        )
    }

    /// 按量付费上限 `config.onDemandCap`,proto-JSON 形如 `{"val": 2500}`
    /// (停用/为 0 时整个字段缺席),单位是积分而非美元。
    ///
    /// 取证结论(2026-08-24,对照 OpenUsage 对同一 `billing?format=credits`
    /// 接口的解码器):响应里只有这个上限,没有任何 on-demand "已花费"
    /// 字段——OpenUsage 也只把它渲染成启用/停用徽章,而不是金额。
    /// ExtraUsage 需要真实的 spentUSD:臆造 0 会把"未开按量"与"按量已
    /// 花 $0"混为一谈,在主池打满、正在按量扣费时尤其误导。因此这里只
    /// 解析并验证 cap 的形状,等拿到带真实已花费字段的响应样本后,再把
    /// (已花费, cap)一起落到 ExtraUsage(spentUSD:monthlyLimitUSD:)。
    static func onDemandCapCredits(_ data: Data) -> Double? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let config = root["config"] as? [String: Any] else {
            return nil
        }
        let raw = config["onDemandCap"]
        let value = ((raw as? [String: Any])?["val"]).flatMap(number) ?? number(raw)
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// `/v1/settings` 的 `subscription_tier_display`,如 "SuperGrok"。
    static func planName(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = (root["subscription_tier_display"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else {
            return nil
        }
        return plan
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return iso8601Fractional.date(from: text) ?? iso8601.date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// 只读发现 Grok CLI 凭证:`~/.grok/auth.json` 是 `{条目名: {key, expires_at, ...}}`
/// 的多账户字典,取第一个带非空 `key` 的条目。过期判定优先 JWT `exp`,
/// 其次条目的 `expires_at`。
struct GrokAuthReader {
    struct Auth: Sendable {
        let token: String
        let expiry: Date?
    }

    var authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".grok/auth.json")

    func load() -> Auth? {
        guard let data = try? Data(contentsOf: authFileURL) else { return nil }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> Auth? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        // 条目按名稳定排序,同一份文件总是选到同一个账户。
        for key in root.keys.sorted() {
            guard let entry = root[key] as? [String: Any],
                  let token = (entry["key"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                continue
            }
            return Auth(token: token, expiry: JWT.expiry(token) ?? entryExpiry(entry))
        }
        return nil
    }

    private static func entryExpiry(_ entry: [String: Any]) -> Date? {
        let raw = (entry["expires_at"] as? String) ?? (entry["expires"] as? String)
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            if let epoch = (entry["expires_at"] as? NSNumber)?.doubleValue {
                return Date(timeIntervalSince1970: epoch > 1e10 ? epoch / 1000 : epoch)
            }
            return nil
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)
    }
}
