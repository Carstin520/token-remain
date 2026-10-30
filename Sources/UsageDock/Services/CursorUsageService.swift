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
        /// Cursor 3.27+ 加密了登录凭证,读取 "Cursor Safe Storage" 需要用户
        /// 主动授权一次(后台刷新从不弹窗)。
        case encryptedLoginNeedsAuthorization
        /// 加密凭证无法解开(钥匙串条目缺失或解出的不是 token)。
        case encryptedLoginUnreadable

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
            case .encryptedLoginNeedsAuthorization:
                return L10n.text("service.cursor.encrypted_login_authorization")
            case .encryptedLoginUnreadable:
                return L10n.text("service.cursor.encrypted_login_unreadable")
            }
        }
    }

    private static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let modelUsageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetAggregatedUsageEvents")!
    /// 按模型拆分只是附加信息:单独的短时限,超时或失败只丢掉这一行,
    /// 不拖住、也不影响额度本身。
    static let modelUsageTimeout: TimeInterval = 6
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "CursorUsage")

    /// - Parameter keychainInteraction: `.allowed` only from an explicit user
    ///   action (授权只读访问), which may show one macOS Keychain prompt for
    ///   Cursor's Safe Storage key; background refresh stays `.disallowed`.
    func fetch(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async throws -> ProviderQuota {
        try await fetch(accessToken: nil, membershipType: nil, now: now, keychainInteraction: keychainInteraction)
    }

    func fetch(
        accessToken routedToken: String?,
        membershipType: String? = nil,
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async throws -> ProviderQuota {
        let token = routedToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth: CursorAuthReader.Auth?
        if let token, !token.isEmpty {
            auth = CursorAuthReader.Auth(accessToken: token, membershipType: membershipType)
        } else {
            switch await CursorAuthReader().resolve(now: now, interaction: keychainInteraction) {
            case .token(let resolved): auth = resolved
            case .sealed(.authorizationRequired): throw ServiceError.encryptedLoginNeedsAuthorization
            case .sealed(.unreadable): throw ServiceError.encryptedLoginUnreadable
            case .missing: auth = nil
            }
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
        if let failure = Self.failure(forStatus: http.statusCode) {
            Self.logger.error("Cursor usage API rejected the request: HTTP \(http.statusCode, privacy: .public)")
            throw failure
        }
        var quota = try CursorAPIUsageParser.parse(data, planName: auth.membershipType, now: now)
        Self.logger.info("Cursor quota served by DashboardService API")
        if let body = CursorModelUsageParser.requestBody(fromCurrentPeriodUsage: data) {
            quota.modelUsage = await Self.fetchModelUsage(accessToken: auth.accessToken, body: body)
        }
        try Task.checkCancellation()
        return quota
    }

    /// 只有 401(未认证)按登录过期处理:exp 未到但服务端已吊销或有时钟
    /// 偏差,处置同过期——打开 Cursor 让它自己续期。403 等其他状态不是
    /// 凭证过期,如实报状态码,不再引导用户反复打开/重登 Cursor(#92)。
    static func failure(forStatus status: Int) -> ServiceError? {
        switch status {
        case 200..<300: return nil
        case 401: return .staleLogin
        default: return .requestFailed(status)
        }
    }

    /// 当前账期内各模型的 token / 费用汇总(Cursor 仪表盘 Usage 页同源)。
    /// 尽力而为:任何失败都返回 nil,卡片只是不显示模型行。
    static func fetchModelUsage(
        accessToken: String,
        body: Data,
        timeout: TimeInterval = modelUsageTimeout,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) async -> [ProviderModelUsage]? {
        var request = URLRequest(url: modelUsageURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let boundedRequest = request
        guard let (data, response) = try? await AsyncDeadline.run(timeout: timeout, operation: {
            try await transport(boundedRequest)
        }), let http = response as? HTTPURLResponse else {
            logger.info("Cursor model usage unavailable: request did not complete")
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            logger.info("Cursor model usage unavailable: HTTP \(http.statusCode, privacy: .public)")
            return nil
        }
        return CursorModelUsageParser.parse(data)
    }
}

/// `DashboardService/GetAggregatedUsageEvents`(Connect JSON)→ 按模型汇总。
/// 请求带账期起止(epoch 毫秒,int64 按 Connect 约定写成字符串);个人账户
/// 不带 teamId,与 GetCurrentPeriodUsage 的 `{}` 请求同一作用域。响应
/// `aggregations[]` 每项为 `{modelIntent, inputTokens, outputTokens,
/// cacheWriteTokens, cacheReadTokens, totalCents}`,int64 同样可能是字符串。
enum CursorModelUsageParser {
    static func requestBody(fromCurrentPeriodUsage data: Data) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let start = integer(object["billingCycleStart"]), start > 0,
              let end = integer(object["billingCycleEnd"]), end > start else {
            return nil
        }
        return try? JSONSerialization.data(
            withJSONObject: ["startDate": String(start), "endDate": String(end)],
            options: [.sortedKeys]
        )
    }

    static func parse(_ data: Data) -> [ProviderModelUsage]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let aggregations = object["aggregations"] as? [[String: Any]] else {
            return nil
        }
        let rows = aggregations.compactMap { item -> ProviderModelUsage? in
            guard let model = (field(item, "modelIntent", "model_intent") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !model.isEmpty else {
                return nil
            }
            let cents = number(field(item, "totalCents", "total_cents"))
            let usage = ProviderModelUsage(
                model: model,
                inputTokens: tokens(field(item, "inputTokens", "input_tokens")),
                outputTokens: tokens(field(item, "outputTokens", "output_tokens")),
                cacheWriteTokens: tokens(field(item, "cacheWriteTokens", "cache_write_tokens")),
                cacheReadTokens: tokens(field(item, "cacheReadTokens", "cache_read_tokens")),
                costCents: cents.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            )
            return usage.totalTokens > 0 || (usage.costCents ?? 0) > 0 ? usage : nil
        }
        return rows.sorted {
            $0.totalTokens != $1.totalTokens
                ? $0.totalTokens > $1.totalTokens
                : ($0.costCents ?? 0) > ($1.costCents ?? 0)
        }
    }

    private static func field(_ item: [String: Any], _ camel: String, _ snake: String) -> Any? {
        item[camel] ?? item[snake]
    }

    private static func tokens(_ value: Any?) -> Int64 {
        max(0, integer(value) ?? 0)
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let text = value as? String { return Int64(text) }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.int64Value }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// GetCurrentPeriodUsage 响应 → ProviderQuota。核心字段:
/// `planUsage.autoPercentUsed` / `planUsage.apiPercentUsed`(0–100,账期内的
/// 两个独立池:Cursor 自家模型与其他模型)——Cursor 仪表盘分开展示,
/// `totalPercentUsed` 只是按额度加权的混合值,单条展示会掩盖先耗尽的池;
/// 两池齐全时用得多的做主窗口,另一池作命名 scoped 窗口;只剩一个池字段
/// 时该命名池直接做主窗口。两池全缺才退回 `totalPercentUsed` 或
/// `totalSpend / limit`(美分,推算百分比)的单条形态。
/// `billingCycleStart` / `billingCycleEnd` 为 epoch 毫秒,窗口即真实账期。
enum CursorAPIUsageParser {
    /// 账期字段缺失时按 30 天整月展示。
    static let defaultCycleMinutes = 43_200

    /// 与 Cursor 仪表盘一致的池名;scopeID 需满足 sync 的 [a-z0-9_-] 约束。
    static let autoPoolName = "Cursor Models"
    static let autoPoolScopeID = "cursor_auto"
    static let apiPoolName = "Other Models"
    static let apiPoolScopeID = "cursor_api"

    /// Cursor 自家模型(Auto、Composer、cursor-*)计入 Cursor Models 池,
    /// 其余模型走 Other Models 池。用量接口只给整个账期一份按模型的列表,
    /// 所以按模型名推断归属。
    static func isCursorModel(_ model: String) -> Bool {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == "auto" || name == "default"
            || name.hasPrefix("composer") || name.hasPrefix("cursor")
    }

    static func parse(_ data: Data, planName: String? = nil, now: Date = .now) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CursorUsageService.ServiceError.invalidResponse
        }
        guard object["enabled"] as? Bool != false else {
            throw CursorUsageService.ServiceError.noActiveSubscription
        }
        guard let planUsage = object["planUsage"] as? [String: Any] else {
            throw CursorUsageService.ServiceError.invalidResponse
        }

        let cycle = billingCycle(object, now: now)
        if let pools = poolQuota(planUsage, cycle: cycle, planName: planName, now: now) {
            return pools
        }
        guard let usedPercent = usedPercent(planUsage) else {
            throw CursorUsageService.ServiceError.invalidResponse
        }
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

    /// 两池并存时的双进度条形态。主窗口(菜单栏/收起态)取已用百分比更高
    /// 的池——它才是真正的瓶颈;另一池以同账期的 scoped 窗口展示。不走
    /// `secondary`:sync 校验拒绝两个同时长的账户级窗口,scoped 则允许。
    private static func poolQuota(
        _ planUsage: [String: Any],
        cycle: (minutes: Int, resetsAt: Date?),
        planName: String?,
        now: Date
    ) -> ProviderQuota? {
        let autoPool = number(planUsage["autoPercentUsed"]).map { (
            name: autoPoolName,
            scopeID: autoPoolScopeID,
            usedPercent: min(100, max(0, $0))
        ) }
        let apiPool = number(planUsage["apiPercentUsed"]).map { (
            name: apiPoolName,
            scopeID: apiPoolScopeID,
            usedPercent: min(100, max(0, $0))
        ) }
        guard let autoPool, let apiPool else {
            // 只有一个池字段时,用该命名池做主窗口(带 poolName,无 scoped
            // 兄弟)——退回混合 totalPercentUsed 会把先耗尽的池重新掩盖;
            // 两个池字段都缺才轮到混合值兜底。
            guard let lone = autoPool ?? apiPool else { return nil }
            return ProviderQuota(
                provider: .cursor,
                primary: QuotaWindow(
                    usedPercent: lone.usedPercent,
                    windowMinutes: cycle.minutes,
                    resetsAt: cycle.resetsAt,
                    poolName: lone.name
                ),
                secondary: nil,
                planName: planLabel(planName),
                capturedAt: now
            )
        }
        let (busier, other) = apiPool.usedPercent > autoPool.usedPercent
            ? (apiPool, autoPool)
            : (autoPool, apiPool)
        return ProviderQuota(
            provider: .cursor,
            primary: QuotaWindow(
                usedPercent: busier.usedPercent,
                windowMinutes: cycle.minutes,
                resetsAt: cycle.resetsAt,
                poolName: busier.name
            ),
            secondary: nil,
            planName: planLabel(planName),
            capturedAt: now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: other.scopeID,
                    displayName: other.name,
                    window: QuotaWindow(
                        usedPercent: other.usedPercent,
                        windowMinutes: cycle.minutes,
                        resetsAt: cycle.resetsAt
                    ),
                    observedAt: now
                )
            ]
        )
    }

    /// 紧凑表面(菜单栏、Dock、提示)按用户选择改看指定池(#92:Other
    /// Models 用尽后 Auto/Composer 仍可用,恒显 0% 没有意义)。只交换主窗口
    /// 与 scoped 兄弟的位置,不丢数据;缓存、同步与卡片仍用解析出的
    /// 用量最高优先形态。所选池不存在(单池或旧缓存)时原样返回。
    static func headlined(_ quota: ProviderQuota, on pool: CursorHeadlinePool) -> ProviderQuota {
        let target: (name: String, scopeID: String)
        switch pool {
        case .busiest: return quota
        case .cursorModels: target = (autoPoolName, autoPoolScopeID)
        case .otherModels: target = (apiPoolName, apiPoolScopeID)
        }
        guard quota.provider == .cursor,
              let formerName = quota.primary.poolName, formerName != target.name,
              let formerScopeID = poolScopeID(named: formerName),
              let sibling = quota.scopedWindows?.first(where: { $0.scopeID == target.scopeID }) else {
            return quota
        }
        var promoted = sibling.window
        promoted.poolName = target.name
        var demoted = quota.primary
        demoted.poolName = nil
        let others = (quota.scopedWindows ?? []).filter { $0.scopeID != target.scopeID }
        return ProviderQuota(
            provider: quota.provider,
            primary: promoted,
            secondary: quota.secondary,
            planName: quota.planName,
            capturedAt: quota.capturedAt,
            extraUsage: quota.extraUsage,
            spend: quota.spend,
            accountBalance: quota.accountBalance,
            scopedWindows: others + [
                ScopedQuotaWindow(
                    scopeID: formerScopeID,
                    displayName: formerName,
                    window: demoted,
                    observedAt: sibling.observedAt
                )
            ],
            // 旧版主窗口的遗留余额字段属于被换下的池,不跟到新主窗口上。
            remainingBalance: nil,
            codexResetCredits: quota.codexResetCredits,
            attribution: quota.attribution,
            modelUsage: quota.modelUsage,
            modelUsagePeriod: quota.modelUsagePeriod
        )
    }

    private static func poolScopeID(named name: String) -> String? {
        switch name {
        case autoPoolName: return autoPoolScopeID
        case apiPoolName: return apiPoolScopeID
        default: return nil
        }
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

/// 只读发现 Cursor 的登录凭证。来源:
/// 1. `state.vscdb`(`ItemTable` 的 `cursorAuth/accessToken`)——Cursor IDE 的
///    主存储,顺带取 `cursorAuth/stripeMembershipType` 作计划名
/// 2. 钥匙串 `cursor-access-token`——这是 `cursor-agent` CLI 自己的登录,
///    只在 CLI 运行时续期,打开 IDE 不会刷新它
/// IDE token 优先;它缺失、或已过期而 CLI token 仍有效且属于同一账号
/// (JWT `sub` 相同)时才用 CLI token,不会悄悄换成另一个账号的额度。
/// Cursor 3.27+ 把 IDE token 加密存放(见 `CursorSafeStorage`):解得开就用
/// 明文 token;解不开时报明确原因,绝不把密文当 token 发出去,也不换用
/// 无法核对账号的 CLI token。
/// 通过 `sqlite3 -readonly` 查询,不锁库、不写入。
struct CursorAuthReader {
    struct Auth: Sendable {
        let accessToken: String
        let membershipType: String?
    }

    /// Why Cursor's sealed IDE login could not be used.
    enum SealedFailure: Error, Sendable, Equatable {
        /// Reading the "Cursor Safe Storage" key needs a one-time approval.
        case authorizationRequired
        /// The key is missing or does not decrypt the value to a token.
        case unreadable
    }

    enum Resolution: Sendable {
        case token(Auth)
        case sealed(SealedFailure)
        case missing
    }

    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "CursorUsage")

    var stateDBURL: URL = URL(
        fileURLWithPath: (stateDBPath as NSString).expandingTildeInPath
    )
    var keychainPayload: @Sendable () -> String? = {
        KeychainRead.genericPassword(service: "cursor-access-token", interaction: .disallowed).payload
    }
    /// The "Cursor Safe Storage" password. Background refresh passes
    /// `.disallowed`; only an explicit user action passes `.allowed`.
    var safeStorageKey: @Sendable (KeychainRead.Interaction) -> KeychainRead.Outcome = { interaction in
        KeychainRead.genericPassword(service: CursorSafeStorage.keychainService, interaction: interaction)
    }
    var keyCache: CursorSafeStorage.KeyCache = .shared

    func load(now: Date = .now) async -> Auth? {
        guard case .token(let auth) = await resolve(now: now, interaction: .disallowed) else { return nil }
        return auth
    }

    func resolve(now: Date = .now, interaction: KeychainRead.Interaction) async -> Resolution {
        var stateToken: String?
        var sealedFailure: SealedFailure?
        if let stored = await stateValue(key: "cursorAuth/accessToken") {
            if CursorSafeStorage.isSealed(stored) {
                switch unseal(stored, interaction: interaction) {
                case .success(let token): stateToken = token
                case .failure(let failure): sealedFailure = failure
                }
            } else {
                stateToken = stored
            }
        }
        if let stateToken, !Self.isExpired(stateToken, now: now) {
            let membership = await stateValue(key: "cursorAuth/stripeMembershipType")
            return .token(Auth(accessToken: stateToken, membershipType: membership))
        }
        let keychainToken = Self.normalized(keychainPayload())
        if sealedFailure == nil, let keychainToken, !Self.isExpired(keychainToken, now: now),
           stateToken.map({ Self.sameAccount($0, keychainToken) }) ?? true {
            Self.logger.info("Cursor token served by the cursor-agent Keychain item")
            return .token(Auth(accessToken: keychainToken, membershipType: nil))
        }
        if let sealedFailure { return .sealed(sealedFailure) }
        // 没有可用的新 token:仍交回 IDE 的过期 token,由调用方报 staleLogin。
        if let stateToken {
            return .token(Auth(accessToken: stateToken, membershipType: nil))
        }
        guard let keychainToken else { return .missing }
        Self.logger.info("Cursor token served by the cursor-agent Keychain item")
        return .token(Auth(accessToken: keychainToken, membershipType: nil))
    }

    /// Decrypts with the cached key first; a stale key falls through to a
    /// fresh Keychain read under the caller's interaction policy.
    private func unseal(_ sealed: String, interaction: KeychainRead.Interaction) -> Result<String, SealedFailure> {
        if let cached = keyCache.key {
            if let token = CursorSafeStorage.decrypt(sealed, key: cached) { return .success(token) }
            keyCache.store(nil)
        }
        let outcome = safeStorageKey(interaction)
        guard let password = outcome.payload else {
            Self.logger.info("Cursor login is sealed; Safe Storage key unavailable (OSStatus \(outcome.status, privacy: .public))")
            return .failure(outcome.needsAuthorization ? .authorizationRequired : .unreadable)
        }
        guard let key = CursorSafeStorage.derivedKey(password: password),
              let token = CursorSafeStorage.decrypt(sealed, key: key) else {
            Self.logger.error("Cursor sealed login did not decrypt with the Safe Storage key")
            return .failure(.unreadable)
        }
        keyCache.store(key)
        Self.logger.info("Cursor sealed login decrypted")
        return .success(token)
    }

    private static func isExpired(_ token: String, now: Date) -> Bool {
        JWT.expiry(token).map { $0 <= now } ?? false
    }

    /// 两个 token 都带 `sub` 且相同才算同一账号;无法确认时不切换来源。
    static func sameAccount(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = JWT.payload(lhs)?["sub"] as? String, !left.isEmpty,
              let right = JWT.payload(rhs)?["sub"] as? String else {
            return false
        }
        return left == right
    }

    private func stateValue(key: String) async -> String? {
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else { return nil }
        let sql = "SELECT value FROM ItemTable WHERE key = '\(key)' LIMIT 1;"
        do {
            let data = try await ProcessRunner.run(
                "/usr/bin/sqlite3",
                arguments: ["-readonly", stateDBURL.path, sql]
            )
            return Self.normalized(String(data: data, encoding: .utf8))
        } catch {
            // sqlite3 的错误输出只有库状态(如 database is locked),不含库内容。
            Self.logger.error("Cursor state.vscdb read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
