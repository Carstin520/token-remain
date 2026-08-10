import Foundation
import OSLog

/// Cursor 月度额度直查。参考 OpenUsage(MIT)的 Cursor provider,但坚持
/// 只读原则:读取 Cursor IDE 自己维护的 access token(`state.vscdb` 优先、
/// 钥匙串兜底),**绝不用 refresh token 代刷**——Cursor 的认证服务器可能
/// 对 refresh token 做轮换检测,代刷会危及用户 IDE 的登录态。
///
/// 代价:token 过期(Cursor 长时间未运行)时数据停更,此时抛出
/// `staleLogin`,界面保留最近缓存并提示用户打开一次 Cursor 恢复。
struct CursorUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case notLoggedIn
        /// token 已过 JWT `exp` 或被服务端 401/403 拒绝——Cursor 自己一运行
        /// 就会续期,所以话术引导用户打开应用而不是重新登录。
        case staleLogin
        case requestFailed(Int)
        case invalidResponse
        case noActiveSubscription

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return L10n.text("service.cursor.not_logged_in")
            case .staleLogin:
                return L10n.format("service.common.stale_login_reopen", "Cursor")
            case .requestFailed(let status):
                return L10n.format("service.common.request_failed", "Cursor", status)
            case .invalidResponse:
                return L10n.format("service.common.invalid_response", "Cursor")
            case .noActiveSubscription:
                return L10n.text("service.cursor.no_subscription")
            }
        }
    }

    private static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "CursorUsage")

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        try await fetch(accessToken: nil, membershipType: nil, now: now)
    }

    func fetch(
        accessToken routedToken: String?,
        membershipType: String? = nil,
        now: Date = .now
    ) async throws -> ProviderQuota {
        let token = routedToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth: CursorAuthReader.Auth?
        if let token, !token.isEmpty {
            auth = CursorAuthReader.Auth(accessToken: token, membershipType: membershipType)
        } else {
            auth = await CursorAuthReader().load()
        }
        guard let auth else {
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            // 服务端拒绝但 exp 还没到(时钟偏差、提前吊销):对用户而言
            // 处置方式相同——打开 Cursor 让它自己续期。
            throw ServiceError.staleLogin
        default:
            throw ServiceError.requestFailed(http.statusCode)
        }
        let quota = try CursorAPIUsageParser.parse(data, planName: auth.membershipType, now: now)
        Self.logger.info("Cursor quota served by DashboardService API")
        return quota
    }
}

/// GetCurrentPeriodUsage 响应 → ProviderQuota。核心字段:
/// `planUsage.totalPercentUsed`(0–100 已用百分比,新计费模型)或
/// `planUsage.totalSpend / planUsage.limit`(美分,推算百分比);
/// `billingCycleStart` / `billingCycleEnd` 为 epoch 毫秒,窗口即真实账期。
enum CursorAPIUsageParser {
    /// 账期字段缺失时按 30 天整月展示。
    static let defaultCycleMinutes = 43_200

    static func parse(_ data: Data, planName: String? = nil, now: Date = .now) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CursorUsageService.ServiceError.invalidResponse
        }
        guard object["enabled"] as? Bool != false else {
            throw CursorUsageService.ServiceError.noActiveSubscription
        }
        guard let planUsage = object["planUsage"] as? [String: Any],
              let usedPercent = usedPercent(planUsage) else {
            throw CursorUsageService.ServiceError.invalidResponse
        }

        let cycle = billingCycle(object, now: now)
        return ProviderQuota(
            provider: .cursor,
            primary: QuotaWindow(
                usedPercent: min(100, max(0, usedPercent)),
                windowMinutes: cycle.minutes,
                resetsAt: cycle.resetsAt
            ),
            secondary: nil,
            planName: planLabel(planName),
            capturedAt: now
        )
    }

    /// "pro" → "Pro";Cursor 的 membership type 是小写单词。
    static func planLabel(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func usedPercent(_ planUsage: [String: Any]) -> Double? {
        if let percent = number(planUsage["totalPercentUsed"]) {
            return percent
        }
        guard let limit = number(planUsage["limit"]), limit > 0 else { return nil }
        let spend = number(planUsage["totalSpend"])
            ?? (limit - (number(planUsage["remaining"]) ?? limit))
        return spend / limit * 100
    }

    private static func billingCycle(_ object: [String: Any], now: Date) -> (minutes: Int, resetsAt: Date?) {
        let start = number(object["billingCycleStart"])
        let end = number(object["billingCycleEnd"])
        guard let end, end > 0 else {
            return (defaultCycleMinutes, nil)
        }
        let resetsAt = Date(timeIntervalSince1970: end / 1000)
        guard let start, end > start else {
            return (defaultCycleMinutes, resetsAt)
        }
        return (max(1, Int((end - start) / 1000 / 60)), resetsAt)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// 只读发现 Cursor IDE 的登录凭证。查找顺序:
/// 1. `state.vscdb`(`ItemTable` 的 `cursorAuth/accessToken`)——Cursor 的
///    主存储,顺带取 `cursorAuth/stripeMembershipType` 作计划名
/// 2. 钥匙串 `cursor-access-token`(新版 Cursor 的备用存储)
/// 通过 `sqlite3 -readonly` 查询,不锁库、不写入。
struct CursorAuthReader {
    struct Auth: Sendable {
        let accessToken: String
        let membershipType: String?
    }

    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    var stateDBURL: URL = URL(
        fileURLWithPath: (stateDBPath as NSString).expandingTildeInPath
    )
    var keychainPayload: @Sendable () -> String? = {
        KeychainRead.genericPassword(service: "cursor-access-token", interaction: .disallowed).payload
    }

    func load() async -> Auth? {
        if let token = await stateValue(key: "cursorAuth/accessToken") {
            let membership = await stateValue(key: "cursorAuth/stripeMembershipType")
            return Auth(accessToken: token, membershipType: membership)
        }
        guard let token = Self.normalized(keychainPayload()) else { return nil }
        return Auth(accessToken: token, membershipType: nil)
    }

    private func stateValue(key: String) async -> String? {
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else { return nil }
        let sql = "SELECT value FROM ItemTable WHERE key = '\(key)' LIMIT 1;"
        guard let data = try? await ProcessRunner.run(
            "/usr/bin/sqlite3",
            arguments: ["-readonly", stateDBURL.path, sql]
        ) else {
            return nil
        }
        return Self.normalized(String(data: data, encoding: .utf8))
    }

    /// state.vscdb 的 value 可能是裸字符串或 JSON 引号包裹的字符串,统一剥掉。
    static func normalized(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.isEmpty ? nil : text
    }
}
