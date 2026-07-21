import Foundation
import OSLog

/// Antigravity(Google 家的 agentic IDE)配额池直查。参考 OpenUsage(MIT)
/// 的 Antigravity provider,坚持只读:读取 Antigravity 存在钥匙串的 Google
/// OAuth token(service `gemini` / account `antigravity`,go-keyring 包装),
/// 调用 Cloud Code 的 RetrieveUserQuotaSummary。**绝不用 Google OAuth 代刷**
/// ——token 过期(Antigravity 长时间未运行)时提示打开一次应用恢复。
struct AntigravityUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case notLoggedIn
        case staleLogin
        case requestFailed(Int)
        case invalidResponse
        case quotaUnavailable

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return "未检测到 Antigravity 登录；安装并登录 Antigravity 后自动接入"
            case .staleLogin:
                return "Antigravity 长时间未使用，登录凭证已过期；打开一次 Antigravity 应用即可恢复额度刷新"
            case .requestFailed(let status):
                return "Antigravity 配额接口请求失败（HTTP \(status)）"
            case .invalidResponse:
                return "Antigravity 配额接口返回了无法识别的内容"
            case .quotaUnavailable:
                return "当前 Antigravity 账户未提供配额池数据"
            }
        }
    }

    private static let quotaSummaryURLs = [
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
        URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    ]
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "AntigravityUsage")

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        guard let token = AntigravityTokenReader().load() else {
            throw ServiceError.notLoggedIn
        }
        if let expiry = token.expiry ?? JWT.expiry(token.accessToken), expiry <= now {
            throw ServiceError.staleLogin
        }

        var lastStatus = 0
        for url in Self.quotaSummaryURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = Data("{}".utf8)
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else {
                continue
            }
            switch http.statusCode {
            case 200..<300:
                let quota = try AntigravityUsageParser.parse(data, now: now)
                Self.logger.info("Antigravity quota served by Cloud Code quota summary")
                return quota
            case 401, 403:
                // 同一个 token 在另一个 base 也必然失败,不再尝试。
                throw ServiceError.staleLogin
            default:
                lastStatus = http.statusCode
                continue
            }
        }
        throw lastStatus > 0 ? ServiceError.requestFailed(lastStatus) : ServiceError.invalidResponse
    }
}

/// RetrieveUserQuotaSummary 响应 → ProviderQuota。响应为
/// `{"groups": [{"buckets": [{bucketId, remainingFraction, resetTime}]}]}`
/// (或包一层 `response`)。四个池按精确 bucketId 匹配:`gemini-5h` /
/// `gemini-weekly` 为主池(映射 primary/secondary),`3p-5h` / `3p-weekly`
/// 是共享的第三方(Claude)池——单卡双窗模型放不下,取主池展示。
/// `remainingFraction` 0…1,翻转为已用百分比。
enum AntigravityUsageParser {
    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AntigravityUsageService.ServiceError.invalidResponse
        }
        let container = (root["response"] as? [String: Any]) ?? root
        guard let groups = container["groups"] as? [[String: Any]] else {
            throw AntigravityUsageService.ServiceError.invalidResponse
        }

        var pools: [String: QuotaWindow] = [:]
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["bucketId"] as? String,
                      pools[id] == nil,
                      let fraction = number(bucket["remainingFraction"]), fraction.isFinite else {
                    continue
                }
                let minutes = id.hasSuffix("-weekly") ? 10_080 : 300
                pools[id] = QuotaWindow(
                    usedPercent: min(100, max(0, (1 - fraction) * 100)),
                    windowMinutes: minutes,
                    resetsAt: isoDate(bucket["resetTime"])
                )
            }
        }

        guard let primary = pools["gemini-5h"] ?? pools["gemini-weekly"] else {
            throw AntigravityUsageService.ServiceError.quotaUnavailable
        }
        let secondary = pools["gemini-5h"] == nil ? nil : pools["gemini-weekly"]
        return ProviderQuota(
            provider: .antigravity,
            primary: primary,
            secondary: secondary,
            planName: nil,
            capturedAt: now
        )
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// 只读发现 Antigravity 的 Google OAuth token:钥匙串 service `gemini`、
/// account `antigravity`,值可能是 go-keyring base64 包装的 JSON
/// `{token: {access_token, expiry}}`,或裸 token / `Bearer x`。
struct AntigravityTokenReader {
    struct Token: Sendable {
        let accessToken: String
        let expiry: Date?
    }

    var keychainPayload: @Sendable () -> String? = {
        KeychainRead.genericPassword(service: "gemini", account: "antigravity")
    }

    func load() -> Token? {
        guard let raw = keychainPayload(),
              let text = GoKeyring.unwrap(raw) else {
            return nil
        }
        return Self.parse(text)
    }

    static func parse(_ text: String) -> Token? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let object = json as? [String: Any] {
                return token(fromObject: object)
            }
            if let string = (json as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                return Token(accessToken: string, expiry: nil)
            }
            return nil
        }
        // 结构化内容坏了就不当裸 token 乱发。
        if text.hasPrefix("{") || text.hasPrefix("[") { return nil }
        if text.hasPrefix("Bearer ") {
            let token = String(text.dropFirst("Bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : Token(accessToken: token, expiry: nil)
        }
        return Token(accessToken: text, expiry: nil)
    }

    private static func token(fromObject object: [String: Any]) -> Token? {
        let source = (object["token"] as? [String: Any]) ?? object
        let accessKeys = ["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken"]
        let access = accessKeys.lazy
            .compactMap { (source[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let access else {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let token = token(fromObject: nested) {
                    return token
                }
            }
            return nil
        }
        let expiryText = ["expiry", "expires_at", "expiresAt"].lazy
            .compactMap { source[$0] as? String }
            .first
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = expiryText.flatMap { fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return Token(accessToken: access, expiry: expiry)
    }
}
