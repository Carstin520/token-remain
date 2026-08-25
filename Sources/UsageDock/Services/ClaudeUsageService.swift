import Darwin
import Foundation
import OSLog

struct ClaudeUsageService {
    let configurationDirectory: URL?

    init(configurationDirectory: URL? = nil) {
        self.configurationDirectory = configurationDirectory
    }

    enum ServiceError: LocalizedError, Sendable {
        case cliNotFound
        case cliTimedOut
        case credentialsUnavailable
        case credentialsAuthorizationRequired
        case invalidStoredCredentials
        case sessionExpired
        case cliLaunchFailed(String)
        case invalidUsageOutput
        case rateLimited(retryAfterSeconds: Int?)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return L10n.text("service.claude.cli_not_found")
            case .cliTimedOut:
                return L10n.text("service.claude.cli_timeout")
            case .credentialsUnavailable:
                return L10n.text("service.claude.credentials_unavailable")
            case .credentialsAuthorizationRequired:
                return L10n.text("service.claude.authorization_required")
            case .invalidStoredCredentials:
                return L10n.text("service.claude.invalid_stored_credentials")
            case .sessionExpired:
                return L10n.text("service.claude.session_expired")
            case .cliLaunchFailed(let detail):
                return L10n.format("service.claude.probe_launch_failed", detail)
            case .invalidUsageOutput:
                return L10n.text("service.claude.invalid_usage_output")
            case .rateLimited(let seconds):
                if let seconds {
                    return L10n.format("service.claude.rate_limited_minutes", max(1, Int((Double(seconds) / 60).rounded(.up))))
                }
                return L10n.text("service.claude.rate_limited")
            }
        }

        var retryDelay: TimeInterval {
            if case .rateLimited(let seconds) = self, let seconds {
                return max(60, TimeInterval(seconds))
            }
            return 300
        }
    }

    /// 主路径:oauth/usage API 直查(只读 Claude Code 凭证,秒级返回)。
    /// 凭证缺失/过期/被拒或响应异常时降级 PTY `/usage` 探针——探针会让
    /// Claude Code 自行完成续期,下一轮 API 直查即可恢复。
    /// 服务端明确限流(429)时不降级:PTY 的 /usage 走同一个接口,
    /// 换个马甲重试只会延长限流。
    func fetch(forceScopedUsageProbe: Bool = false) async throws -> ProviderQuota {
        let logger = Logger(subsystem: "com.jamesli.usagedock", category: "ClaudeUsage")
        let environment = profileEnvironment
        do {
            let quota = try await ClaudeOAuthUsageService().fetch(
                environment: environment,
                isolatedConfiguration: configurationDirectory != nil
            )
            let supplemented = await ClaudeScopedUsageSupplement.shared.supplement(
                quota,
                cacheKey: cacheKey,
                configurationDirectory: configurationDirectory,
                forceProbe: forceScopedUsageProbe
            )
            logger.info("Claude quota served by oauth/usage API; Fable available: \(supplemented.fableWindow != nil, privacy: .public)")
            return supplemented
        } catch let error as ClaudeOAuthUsageService.APIError {
            if case .rateLimited(let seconds) = error {
                throw ServiceError.rateLimited(retryAfterSeconds: seconds)
            }
            guard Self.probeCanRecover(from: error), ClaudeCLIUsageProbe.isAvailable else {
                throw Self.noCLIFallbackError(for: error)
            }
            // Missing/expired credentials normally fall through to the PTY so
            // Claude Code can refresh them. When Claude itself explicitly says
            // it is logged out, however, the PTY can only sit on the login
            // screen until our 45-second deadline. Surface the real recovery
            // action immediately instead of misclassifying it as a timeout.
            if Self.mayReflectSignedOutClaude(error),
               await ClaudeCLIUsageProbe.isExplicitlyLoggedOut(
                   configurationDirectory: configurationDirectory
               ) {
                throw ServiceError.credentialsUnavailable
            }
            // .notice 起才会持久化到 unified log。降级原因必须留痕:出现
            // "读取超时"时,事后唯一能区分"凭证过期"和"网络故障"的就是这条。
            logger.notice("Claude API path unavailable (\(error.localizedDescription, privacy: .public)); falling back to PTY probe")
        } catch {
            // 传输层错误(离线、请求超时)不降级:PTY 里的 /usage 读的是
            // 同一个接口,网络不通时探针只会再白等 45 秒,然后把一个普通的
            // 网络问题误报成"读取超时"。保留缓存快照,下一轮直查即可。
            logger.notice("Claude API transport failure (\(error.localizedDescription, privacy: .public)); keeping cached snapshot instead of probing")
            throw error
        }
        let output = try await ClaudeCLIUsageProbe.run(
            configurationDirectory: configurationDirectory
        )
        return try ClaudeCLIUsageParser.parse(output)
    }

    private var cacheKey: String {
        configurationDirectory?.standardizedFileURL.path ?? "system"
    }

    private var profileEnvironment: [String: String] {
        ProviderAccountProcessEnvironment.claude(
            base: ProcessInfo.processInfo.environment,
            configurationDirectory: configurationDirectory
        )
    }

    /// Which API failures a signed-out Claude Code would equally well explain.
    /// Narrowing this to "no credential found" was wrong: a keychain that
    /// answers `errSecAuthFailed` looks nothing like a missing item, yet it
    /// leaves Claude Code just as signed out — and the probe then spent thirty
    /// seconds on a login screen every refresh round before reporting a timeout
    /// for an account that simply needed signing in again. Each of these is
    /// worth one cheap `auth status` question first.
    static func mayReflectSignedOutClaude(
        _ error: ClaudeOAuthUsageService.APIError
    ) -> Bool {
        switch error {
        case .credentialsUnavailable, .credentialsAuthorizationRequired,
             .credentialsExpired, .invalidStoredCredentials, .tokenRejected:
            return true
        // A transport or protocol failure says nothing about the session, and
        // rate limiting never reaches here.
        case .rateLimited, .requestFailed, .invalidResponse:
            return false
        }
    }

    /// PTY 降级一次要付出最多 45 秒的进程成本,只在探针可能修复问题时
    /// 才值得:凭证类失败让 Claude Code 自己续期,`invalidResponse` 覆盖
    /// API 不返回订阅会话行的账户(此时 /usage 画面是唯一数据源)。
    /// 服务端明确拒绝(429/5xx)时换个入口没有意义——探针读的是同一个
    /// 接口,只会把服务端故障拖成一条"读取超时"。
    static func probeCanRecover(
        from error: ClaudeOAuthUsageService.APIError
    ) -> Bool {
        switch error {
        case .credentialsUnavailable, .credentialsAuthorizationRequired,
             .credentialsExpired, .invalidStoredCredentials, .tokenRejected,
             .invalidResponse:
            return true
        case .rateLimited, .requestFailed:
            return false
        }
    }

    static func noCLIFallbackError(
        for error: ClaudeOAuthUsageService.APIError
    ) -> Error {
        switch error {
        case .credentialsUnavailable:
            ServiceError.credentialsUnavailable
        case .credentialsAuthorizationRequired:
            ServiceError.credentialsAuthorizationRequired
        case .credentialsExpired:
            ServiceError.sessionExpired
        case .invalidStoredCredentials:
            ServiceError.invalidStoredCredentials
        case .tokenRejected:
            ServiceError.sessionExpired
        case .invalidResponse:
            ServiceError.invalidUsageOutput
        case .rateLimited(let seconds):
            ServiceError.rateLimited(retryAfterSeconds: seconds)
        case .requestFailed:
            error
        }
    }
}

/// The oauth endpoint does not expose model-scoped windows for every account,
/// while Claude Code's read-only `/usage` screen can still show Fable. Probe
/// only when the authoritative API snapshot lacks Fable and cache the result so
/// one-minute sync mode does not repeatedly launch the CLI.
private actor ClaudeScopedUsageSupplement {
    static let shared = ClaudeScopedUsageSupplement()

    private let refreshInterval: TimeInterval = 300
    private let staleRetention: TimeInterval = 900
    private struct Entry {
        var cachedWindows: [ScopedQuotaWindow] = []
        var lastAttempt: Date?
        var lastSuccess: Date?
    }

    private var entries: [String: Entry] = [:]

    func supplement(
        _ quota: ProviderQuota,
        cacheKey: String,
        configurationDirectory: URL?,
        now: Date = .now,
        forceProbe: Bool = false
    ) async -> ProviderQuota {
        var entry = entries[cacheKey] ?? Entry()
        if quota.fableWindow != nil {
            entry.cachedWindows = quota.uniqueScopedWindows
            entry.lastSuccess = now
            entries[cacheKey] = entry
            return quota
        }

        if !forceProbe,
           let lastAttempt = entry.lastAttempt,
           now.timeIntervalSince(lastAttempt) < refreshInterval {
            return mergingFreshCache(into: quota, entry: entry, now: now)
        }
        entry.lastAttempt = now
        entries[cacheKey] = entry

        guard ClaudeCLIUsageProbe.isAvailable,
              !(await ClaudeCLIUsageProbe.isExplicitlyLoggedOut(
                  configurationDirectory: configurationDirectory
              )) else {
            return mergingFreshCache(into: quota, entry: entry, now: now)
        }

        do {
            let output = try await ClaudeCLIUsageProbe.run(
                configurationDirectory: configurationDirectory
            )
            let supplemental = try ClaudeCLIUsageParser.parse(output, now: now)
            guard supplemental.fableWindow != nil else {
                return mergingFreshCache(into: quota, entry: entry, now: now)
            }
            entry.cachedWindows = supplemental.uniqueScopedWindows
            entry.lastSuccess = now
            entries[cacheKey] = entry
            return quota.mergingScopedWindows(entry.cachedWindows)
        } catch {
            Logger(subsystem: "com.jamesli.usagedock", category: "ClaudeUsage")
                .notice("Claude Fable supplement unavailable: \(error.localizedDescription, privacy: .public)")
            return mergingFreshCache(into: quota, entry: entry, now: now)
        }
    }

    private func mergingFreshCache(
        into quota: ProviderQuota,
        entry: Entry,
        now: Date
    ) -> ProviderQuota {
        guard let lastSuccess = entry.lastSuccess,
              now.timeIntervalSince(lastSuccess) < staleRetention else {
            return quota
        }
        return quota.mergingScopedWindows(entry.cachedWindows)
    }
}

enum ClaudeCLIAuthStatusParser {
    static func isExplicitlyLoggedOut(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else {
            return false
        }
        return !loggedIn
    }
}

enum ClaudeCLIUsageParser {
    private struct PercentReading {
        let usedPercent: Double
    }

    private struct UsageReading {
        let usedPercent: Double
        let resetDescription: String?
    }

    static func parse(_ data: Data, now: Date = .now, calendar: Calendar = .current) throws -> ProviderQuota {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ClaudeUsageService.ServiceError.invalidUsageOutput
        }
        let text = cleanedTerminalText(raw)
        let sessionReadings = sessionReadings(in: text)
        // 账户级 5 小时窗只能来自无 scope 的 `Current session` 行;带 scope
        // 的行(如 `Current session (Fable)`)另行进 scoped 窗口。
        let accountSessionReadings = sessionReadings.filter { $0.scopeName == nil }
        let weeklyReadings = weeklyReadings(in: text)
        let generalWeeklyReadings = weeklyReadings.filter(\.isGeneral)
        guard let sessionReading = accountSessionReadings.last,
              let generalWeeklyReading = generalWeeklyReadings.last else {
            throw ClaudeUsageService.ServiceError.invalidUsageOutput
        }

        // Associate each reset with its labeled row. Both current layouts can
        // express session and weekly resets as relative durations, so the old
        // month-vs-time heuristic cannot distinguish them.
        //
        // A percentage only ever moves forward, so the freshest paint wins for
        // it. A reset does not: any single paint can lose glyphs, and a damaged
        // one still parses into a confident, wrong date. Resolve resets from
        // every copy of their row instead — see `resolveReset`.
        let primaryReset = resolveReset(
            in: accountSessionReadings.compactMap(\.resetDescription),
            windowMinutes: 300,
            now: now,
            calendar: calendar
        )
        let secondaryReset = resolveReset(
            in: generalWeeklyReadings.compactMap(\.resetDescription),
            windowMinutes: 10_080,
            now: now,
            calendar: calendar
        )
        var scopedOrder: [String] = []
        var latestByScope: [String: NamedWeeklyReading] = [:]
        var descriptionsByScope: [String: [String]] = [:]
        for reading in weeklyReadings where !reading.isGeneral {
            guard let scopeID = scopeID(for: reading.name) else { continue }
            if latestByScope[scopeID] == nil {
                scopedOrder.append(scopeID)
            }
            // PTY capture can contain several repainted copies of the same
            // section. The final copy is the freshest complete reading.
            latestByScope[scopeID] = reading
            if let description = reading.resetDescription {
                descriptionsByScope[scopeID, default: []].append(description)
            }
        }
        let scopedWeeklyWindows = scopedOrder.compactMap { scopeID -> ScopedQuotaWindow? in
            guard let reading = latestByScope[scopeID] else { return nil }
            return ScopedQuotaWindow(
                scopeID: scopeID,
                displayName: reading.name,
                window: QuotaWindow(
                    usedPercent: reading.usedPercent,
                    windowMinutes: 10_080,
                    // Every weekly row shares one window, so the corroborated
                    // general reset is the right stand-in when this row's own
                    // copies were all unreadable.
                    resetsAt: resolveReset(
                        in: descriptionsByScope[scopeID] ?? [],
                        windowMinutes: 10_080,
                        now: now,
                        calendar: calendar
                    ) ?? secondaryReset
                ),
                observedAt: now
            )
        }

        // 带 scope 的 `Current session (X)` 行 → 5 小时 scoped 窗口。scopeID
        // 用 scope 名 slug 化后加 `_session` 后缀,与 weekly 侧的裸 slug
        // (如 `fable`)天然区分,也与 Codex 模型池的后缀约定一致。
        var scopedSessionOrder: [String] = []
        var latestSessionByScope: [String: NamedSessionReading] = [:]
        var sessionDescriptionsByScope: [String: [String]] = [:]
        for reading in sessionReadings {
            guard let name = reading.scopeName, let baseID = scopeID(for: name) else { continue }
            // scopeID 上限 32 字符,给 `_session` 后缀预留 8 个。
            let sessionScopeID = String(baseID.prefix(24)) + "_session"
            if latestSessionByScope[sessionScopeID] == nil {
                scopedSessionOrder.append(sessionScopeID)
            }
            // PTY capture can contain several repainted copies of the same
            // section. The final copy is the freshest complete reading.
            latestSessionByScope[sessionScopeID] = reading
            if let description = reading.resetDescription {
                sessionDescriptionsByScope[sessionScopeID, default: []].append(description)
            }
        }
        let scopedSessionWindows = scopedSessionOrder.compactMap { scopeID -> ScopedQuotaWindow? in
            guard let reading = latestSessionByScope[scopeID],
                  let name = reading.scopeName else { return nil }
            return ScopedQuotaWindow(
                scopeID: scopeID,
                displayName: name,
                window: QuotaWindow(
                    usedPercent: reading.usedPercent,
                    windowMinutes: 300,
                    // 同一次会话共用一个 5 小时窗,自己的 reset 读不出来时
                    // 用账户级会话 reset 兜底,与 weekly 侧的兜底对称。
                    resetsAt: resolveReset(
                        in: sessionDescriptionsByScope[scopeID] ?? [],
                        windowMinutes: 300,
                        now: now,
                        calendar: calendar
                    ) ?? primaryReset
                ),
                observedAt: now
            )
        }

        // 会话窗在前、周窗在后,呼应主卡 5h+7d 的堆叠顺序。
        let scopedWindows = scopedSessionWindows + scopedWeeklyWindows
        return ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(
                usedPercent: sessionReading.usedPercent,
                windowMinutes: 300,
                resetsAt: primaryReset
            ),
            secondary: QuotaWindow(
                usedPercent: generalWeeklyReading.usedPercent,
                windowMinutes: 10_080,
                resetsAt: secondaryReset
            ),
            planName: nil,
            capturedAt: now,
            scopedWindows: scopedWindows.isEmpty ? nil : scopedWindows
        )
    }

    static func hasCompleteUsage(in data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        let text = cleanedTerminalText(raw)
        // 完整性只看账户级读数:一条带 scope 的会话行不能代表账户 5h 窗
        // 已经画全。
        guard let session = sessionReadings(in: text).last(where: { $0.scopeName == nil }),
              let weekly = weeklyReadings(in: text).last(where: \.isGeneral) else {
            return false
        }
        return session.resetDescription != nil && weekly.resetDescription != nil
    }

    static func containsTrustPrompt(in data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        return whitespaceCollapsedTerminalText(raw).contains("trustthisfolder")
    }

    static func shouldSendUsageCommand(
        in data: Data,
        startedAt: Date,
        lastSentAt: Date?,
        now: Date,
        retryInterval: TimeInterval = 5
    ) -> Bool {
        guard let raw = String(data: data, encoding: .utf8),
              !whitespaceCollapsedTerminalText(raw).contains("currentsession") else {
            return false
        }
        return now.timeIntervalSince(lastSentAt ?? startedAt) >= retryInterval
    }

    private static func whitespaceCollapsedTerminalText(_ raw: String) -> String {
        cleanedTerminalText(raw)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    private static func cleanedTerminalText(_ raw: String) -> String {
        let escape = "\u{001B}"
        var text = raw
        text = text.replacingOccurrences(
            of: "\(escape)\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\(escape)\\][^\u{0007}]*(?:\u{0007}|\(escape)\\\\)",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\(escape)[()][A-Za-z0-9]",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\u{0008}", with: "")
        text = text.replacingOccurrences(of: "\u{000E}", with: "")
        text = text.replacingOccurrences(of: "\u{000F}", with: "")
        return text
    }

    private static func percentReadings(in text: String) -> [PercentReading] {
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*(used|left|remaining)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let directionRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[numberRange]) else {
                return nil
            }
            let direction = text[directionRange].lowercased()
            let used = direction == "used" ? number : 100 - number
            return PercentReading(usedPercent: min(100, max(0, used)))
        }
    }

    private struct NamedWeeklyReading {
        let name: String
        let usedPercent: Double
        let resetDescription: String?

        var isGeneral: Bool {
            ScopedQuotaWindow.isGeneralWeeklyLabel(name)
        }
    }

    private static func scopeID(for name: String) -> String? {
        let value = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.isEmpty ? nil : String(value.prefix(32))
    }

    private static func usageReading(in body: String) -> UsageReading? {
        guard let percent = percentReadings(in: body).first else { return nil }
        return UsageReading(
            usedPercent: percent.usedPercent,
            resetDescription: resetDescriptions(in: body).first
        )
    }

    private struct NamedSessionReading {
        /// nil 表示账户级 5 小时窗;非 nil 是 `Current session (X)` 括号里的
        /// 模型/产品 scope 名。
        let scopeName: String?
        let usedPercent: Double
        let resetDescription: String?
    }

    /// `Current session` 行与 weekly 侧同一处理方式:scope 名只允许出现在
    /// 同一行的括号里,不允许跨行。带 scope 的会话读数进 scoped 窗口,
    /// 只有无 scope 的读数才是账户级 5 小时窗——否则模型级会话额度会
    /// 顶掉账户 5h(旧的 last-wins bug)。
    private static func sessionReadings(in text: String) -> [NamedSessionReading] {
        let pattern = #"(?is)Current[ \t]*session([^\r\n]*)(.*?)(?=Current[ \t]*(?:week|session)|Weekly[ \t]*limits|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let headerRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { return nil }
            let header = text[headerRange].trimmingCharacters(in: .whitespacesAndNewlines)
            var scopeName: String?
            if let opening = header.firstIndex(of: "(") {
                // 括号残缺(重绘丢字)时整条丢弃,与 legacyWeeklyReadings
                // 一致:读数属于哪个 scope 已不可判,绝不能顶替账户级窗口。
                guard let closing = header[header.index(after: opening)...].firstIndex(of: ")") else {
                    return nil
                }
                let name = String(header[header.index(after: opening)..<closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // `(all models)` 一类通用标签仍是账户级读数,不算 scope。
                scopeName = (name.isEmpty || ScopedQuotaWindow.isGeneralWeeklyLabel(name)) ? nil : name
            }
            // 无 scope 的读数保持修复前的解析方式:header 里的残帧文本并回
            // body 一起解析,确保没有 scoped session 行时行为逐字节一致。
            let body = scopeName == nil
                ? String(text[headerRange]) + String(text[bodyRange])
                : String(text[bodyRange])
            guard let reading = usageReading(in: body) else { return nil }
            return NamedSessionReading(
                scopeName: scopeName,
                usedPercent: reading.usedPercent,
                resetDescription: reading.resetDescription
            )
        }
    }

    private static func weeklyReadings(in text: String) -> [NamedWeeklyReading] {
        legacyWeeklyReadings(in: text) + modernWeeklyReadings(in: text)
    }

    /// Older Claude builds render weekly caps as `Current week (Fable)`.
    /// Preserve the general row too so percentages and resets are associated
    /// with their labels instead of inferred from global reading order.
    private static func legacyWeeklyReadings(in text: String) -> [NamedWeeklyReading] {
        // A PTY repaint can leave an opening parenthesis without its matching
        // close on that line. Do not let the model name cross a line boundary:
        // otherwise the progress bar and reset text become a bogus scoped
        // label that later fails the encrypted mobile snapshot allowlist.
        let pattern = #"(?is)Current[ \t]*week([^\r\n]*)(.*?)(?=Current[ \t]*(?:week|session)|Weekly[ \t]*limits|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let headerRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { return nil }
            let header = text[headerRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if header.isEmpty {
                name = "all models"
            } else {
                guard let opening = header.firstIndex(of: "("),
                      let closing = header[header.index(after: opening)...].firstIndex(of: ")") else {
                    return nil
                }
                name = String(header[header.index(after: opening)..<closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Terminal repainting can drop glyphs anywhere in the label and
            // turn `all models` into `all odels`, `ll models`, or a copy caught
            // before the trailing `s` painted. Every one of those is still the
            // general weekly row, not a model-scoped quota.
            let body = String(text[bodyRange])
            guard let reading = usageReading(in: body) else { return nil }
            return NamedWeeklyReading(
                name: name,
                usedPercent: reading.usedPercent,
                resetDescription: reading.resetDescription
            )
        }
    }

    /// New Claude builds group plain labels (`All models`, `Fable`) under a
    /// `Weekly limits` heading. A label becomes a quota row only when its next
    /// few painted lines contain both a usage percentage and a reset; this
    /// keeps the Fable information banner and help link out of scoped windows.
    private static func modernWeeklyReadings(in text: String) -> [NamedWeeklyReading] {
        let lines = text.components(separatedBy: .newlines)
        var isInsideWeeklyLimits = false
        var result: [NamedWeeklyReading] = []

        for index in lines.indices {
            let line = compactLine(lines[index])
            let canonical = canonicalLine(line)
            if canonical == "weeklylimits" {
                isInsideWeeklyLimits = true
                continue
            }
            if canonical == "currentsession" || canonical.hasPrefix("currentweek") {
                isInsideWeeklyLimits = false
                continue
            }
            guard isInsideWeeklyLimits, let name = weeklyLabelCandidate(line) else {
                continue
            }

            var bodyLines: [String] = []
            let upperBound = min(lines.count, index + 7)
            guard index + 1 < upperBound else { continue }
            for bodyIndex in (index + 1)..<upperBound {
                let bodyLine = compactLine(lines[bodyIndex])
                let bodyCanonical = canonicalLine(bodyLine)
                if bodyCanonical == "weeklylimits"
                    || bodyCanonical == "currentsession"
                    || bodyCanonical.hasPrefix("currentweek") {
                    break
                }
                // A new label before both metrics means the candidate was
                // banner/help copy, not a quota row.
                if weeklyLabelCandidate(bodyLine) != nil {
                    break
                }
                bodyLines.append(bodyLine)
                let body = bodyLines.joined(separator: "\n")
                if let reading = usageReading(in: body), reading.resetDescription != nil {
                    result.append(
                        NamedWeeklyReading(
                            name: name,
                            usedPercent: reading.usedPercent,
                            resetDescription: reading.resetDescription
                        )
                    )
                    break
                }
            }
        }
        return result
    }

    private static func compactLine(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalLine(_ value: String) -> String {
        value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func weeklyLabelCandidate(_ line: String) -> String? {
        let compact = compactLine(line)
        let canonical = canonicalLine(compact)
        guard !compact.isEmpty, compact.count <= 48,
              !compact.contains("%"), !canonical.hasPrefix("resets"),
              canonical != "weeklylimits", canonical != "currentsession",
              !canonical.hasPrefix("currentweek") else {
            return nil
        }
        if ScopedQuotaWindow.isGeneralWeeklyLabel(compact) {
            return compact
        }

        let lowercased = compact.lowercased()
        guard !lowercased.contains("learn more"),
              !lowercased.contains("usage limits"),
              !lowercased.contains("included"),
              !lowercased.contains("restart claude"),
              !lowercased.contains("://"),
              compact.split(whereSeparator: \.isWhitespace).count <= 5 else {
            return nil
        }
        let punctuation = CharacterSet(charactersIn: "-._/+")
        guard compact.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
                || punctuation.contains(scalar)
        }) else {
            return nil
        }
        return compact
    }

    private static func resetDescriptions(in text: String) -> [String] {
        let pattern = #"resets?\s*([^\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let value = text[range]
                .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    /// One capture holds several repainted copies of the same row, and a single
    /// damaged copy still parses into a confident, wrong date — a dropped `at`
    /// once turned `Aug 14 at 1pm` into the same day a year out. Trust the value
    /// the copies agree on instead of the freshest one.
    private static func resolveReset(
        in descriptions: [String],
        windowMinutes: Int,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        var order: [Date] = []
        var counts: [Date: Int] = [:]
        for description in descriptions {
            guard let date = parseResetDate(
                description,
                now: now,
                calendar: calendar,
                windowMinutes: windowMinutes
            ) else {
                continue
            }
            if counts[date] == nil { order.append(date) }
            counts[date, default: 0] += 1
        }
        guard let best = counts.values.max() else { return nil }
        // Every rule that recovers from a damaged reading pushes the result
        // further out (midnight rolls to next year, a passed time rolls to
        // tomorrow), so among equally corroborated values the earliest is the
        // one least likely to be an artifact.
        return order.filter { counts[$0] == best }.min()
    }

    /// A window's reset can never sit further out than the window is long. The
    /// slack only absorbs the minute-level rounding in Claude Code's own label.
    private static func plausibleReset(
        _ date: Date?,
        now: Date,
        windowMinutes: Int
    ) -> Date? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        guard windowMinutes > 0 else { return date }
        return interval <= Double(windowMinutes) * 60 + 300 ? date : nil
    }

    /// A reset survives only when the text still carries a complete time, the
    /// form suits the window it was read from, and the result lands inside that
    /// window. Anything else returns nil: a missing reset renders honestly, an
    /// invented one silently misinforms.
    private static func parseResetDate(
        _ description: String,
        now: Date,
        calendar sourceCalendar: Calendar,
        windowMinutes: Int
    ) -> Date? {
        let calendar = sourceCalendar
        let compact = description
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // `(?=\d)` also accepts `in2days`: a repaint that swallows spaces still
        // carries every digit the duration needs.
        if let inRange = compact.range(
            of: #"\bin(?:\b|(?=\d))"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let relative = String(compact[inRange.upperBound...])
            let days = firstMatch(#"\b(\d+)\s*(?:days?|d)"#, in: relative)
                .flatMap { capture(1, from: $0, in: relative) }
                .flatMap(Int.init) ?? 0
            let hours = firstMatch(#"\b(\d+)\s*(?:hours?|hrs?|h)"#, in: relative)
                .flatMap { capture(1, from: $0, in: relative) }
                .flatMap(Int.init) ?? 0
            let minutes = firstMatch(#"\b(\d+)\s*(?:minutes?|mins?|m)"#, in: relative)
                .flatMap { capture(1, from: $0, in: relative) }
                .flatMap(Int.init) ?? 0
            let seconds = days * 86_400 + hours * 3_600 + minutes * 60
            if seconds > 0 {
                return plausibleReset(
                    calendar.date(byAdding: .second, value: seconds, to: now),
                    now: now,
                    windowMinutes: windowMinutes
                )
            }
        }

        // Parse the more specific month/day form first. A value such as
        // "Jul 24 at 1pm" also contains a valid time-only substring; matching
        // that first would silently turn the weekly reset into tomorrow at 1pm.
        //
        // The time of day is mandatory here. The optional group this pattern
        // used to carry meant a repaint that dropped `at`, `1pm`, or a single
        // glyph of either (`Aug 14 a 1pm`) still matched `Aug 14`, defaulted to
        // midnight, found it already past, and rolled it a full year forward.
        // `\s*` keeps the same text readable once a repaint swallows its
        // spaces (`Aug14at1pm`).
        if let match = firstMatch(
            #"\b([A-Za-z]{3,9})\s*(\d{1,2})\s*at\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#,
            in: compact
        ), let monthText = capture(1, from: match, in: compact),
           let dayText = capture(2, from: match, in: compact),
           let hourText = capture(3, from: match, in: compact),
           let month = monthNumber(monthText) {
            let minuteText = capture(4, from: match, in: compact)
            let meridiem = capture(5, from: match, in: compact)?.lowercased()
            // A lone hour is ambiguous between a real 24-hour label and the
            // wreckage of one, so require either explicit minutes or a meridiem.
            guard minuteText != nil || meridiem != nil else { return nil }

            var components = calendar.dateComponents([.year], from: now)
            components.month = month
            components.day = Int(dayText)
            components.minute = minuteText.flatMap(Int.init) ?? 0
            components.second = 0

            var hour = Int(hourText) ?? 0
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
            components.hour = hour

            guard var date = calendar.date(from: components) else { return nil }
            // Only a genuine year boundary reaches this now: a reset printed as
            // `Jan 2 at 1pm` in late December really is next year's date.
            if date <= now {
                date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
            }
            return plausibleReset(date, now: now, windowMinutes: windowMinutes)
        }

        // A bare clock time cannot express a reset more than a day out, so a
        // longer window reading one has lost its date to a repaint.
        guard windowMinutes <= 1_440 else { return nil }
        if let match = firstMatch(#"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, in: compact),
           let hourText = capture(1, from: match, in: compact) {
            var hour = Int(hourText) ?? 0
            let minute = capture(2, from: match, in: compact).flatMap(Int.init) ?? 0
            let meridiem = capture(3, from: match, in: compact)?.lowercased()
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }

            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard var date = calendar.date(from: components) else { return nil }
            if date <= now {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return plausibleReset(date, now: now, windowMinutes: windowMinutes)
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func capture(_ index: Int, from match: NSTextCheckingResult, in text: String) -> String? {
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }

    private static func monthNumber(_ value: String) -> Int? {
        let prefix = value.lowercased().prefix(3)
        return [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4,
            "may": 5, "jun": 6, "jul": 7, "aug": 8,
            "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ][String(prefix)]
    }

}

private enum ClaudeCLIUsageProbe {
    static var isAvailable: Bool {
        claudeExecutable() != nil
    }

    static func isExplicitlyLoggedOut(
        configurationDirectory: URL? = nil,
        timeout: TimeInterval = 2
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let executable = claudeExecutable() else { return false }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executable
            process.arguments = ["auth", "status", "--json"]
            process.standardOutput = stdout
            process.standardError = stderr
            process.environment = profileEnvironment(configurationDirectory)

            do {
                try process.run()
            } catch {
                return false
            }

            let deadline = Date().addingTimeInterval(max(0.1, timeout))
            while process.isRunning && Date() < deadline {
                usleep(25_000)
            }
            guard !process.isRunning else {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(0.1)
                while process.isRunning && Date() < terminationDeadline {
                    usleep(10_000)
                }
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                return false
            }

            process.waitUntilExit()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            if ClaudeCLIAuthStatusParser.isExplicitlyLoggedOut(output) {
                return true
            }
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            return ClaudeCLIAuthStatusParser.isExplicitlyLoggedOut(errorOutput)
        }.value
    }

    /// 45 秒预算:冷启动的 Claude Code(自动更新检查、MCP 加载)可能
    /// 前 10–20 秒都没进主界面,再算上 /usage 渲染和 5 秒的 Fable 段
    /// 收尾,30 秒经常差一口气。探针有了失败退避后只会低频运行,一次
    /// 成功探针能让 token 续期、换来之后数小时的秒级 API 直查,比多次
    /// 失败的 30 秒便宜;45 也仍在 60 秒的活跃刷新节奏之内。
    static func run(
        configurationDirectory: URL? = nil,
        timeout: TimeInterval = 45
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let executable = claudeExecutable() else {
                throw ClaudeUsageService.ServiceError.cliNotFound
            }
            let probeDirectory = try prepareProbeDirectory()

            var master: Int32 = -1
            var slave: Int32 = -1
            // Claude Code's /usage overlay is optimized for a standard terminal.
            // Very wide PTYs can emit the session percentage before the reset rows
            // finish rendering, while 80 columns consistently paints both windows.
            var windowSize = winsize(ws_row: 60, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
                throw ClaudeUsageService.ServiceError.cliLaunchFailed(String(cString: strerror(errno)))
            }
            defer { Darwin.close(master) }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["--allowed-tools", ""]
            process.currentDirectoryURL = probeDirectory
            var environment = profileEnvironment(configurationDirectory)
            environment["TERM"] = "xterm-256color"
            environment["PATH"] = pathWithClaudeHints(environment["PATH"])
            process.environment = environment

            let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            process.standardInput = terminal
            process.standardOutput = terminal
            process.standardError = terminal

            do {
                try process.run()
            } catch {
                Darwin.close(slave)
                throw ClaudeUsageService.ServiceError.cliLaunchFailed(error.localizedDescription)
            }
            Darwin.close(slave)

            let flags = fcntl(master, F_GETFL)
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

            var output = Data()
            let startedAt = Date()
            var lastUsageSentAt: Date?
            var lastInputAt = Date.distantPast
            var handledTrustPrompt = false
            var completedAt: Date?

            while process.isRunning && Date().timeIntervalSince(startedAt) < timeout {
                readAvailable(from: master, into: &output)
                let now = Date()

                if !handledTrustPrompt && ClaudeCLIUsageParser.containsTrustPrompt(in: output) {
                    write("\r", to: master)
                    handledTrustPrompt = true
                    // If `/usage` was typed before the trust dialog appeared,
                    // schedule it again after accepting the default option.
                    lastUsageSentAt = nil
                    lastInputAt = now
                } else if ClaudeCLIUsageParser.shouldSendUsageCommand(
                    in: output,
                    startedAt: startedAt,
                    lastSentAt: lastUsageSentAt,
                    now: now
                ) {
                    write("/usage\r", to: master)
                    lastUsageSentAt = now
                    lastInputAt = now
                } else if now.timeIntervalSince(lastInputAt) >= 0.8 {
                    write("\r", to: master)
                    lastInputAt = now
                }

                if ClaudeCLIUsageParser.hasCompleteUsage(in: output) {
                    if completedAt == nil { completedAt = now }
                    // The two general rows arrive first; give the terminal one
                    // more paint cycle for a trailing `Current week (Fable)`
                    // section before stopping the otherwise-complete probe.
                    if now.timeIntervalSince(completedAt!) >= 5.0 { break }
                }
                usleep(80_000)
            }

            readAvailable(from: master, into: &output)
            stop(process, terminal: master)
            readAvailable(from: master, into: &output)

            guard ClaudeCLIUsageParser.hasCompleteUsage(in: output) else {
                if Date().timeIntervalSince(startedAt) >= timeout {
                    throw ClaudeUsageService.ServiceError.cliTimedOut
                }
                throw ClaudeUsageService.ServiceError.invalidUsageOutput
            }
            return output
        }.value
    }

    private static func claudeExecutable() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["USAGEDOCK_CLAUDE_COMMAND"], !override.isEmpty {
            candidates.append(override)
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/claude" })
        }
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func prepareProbeDirectory() throws -> URL {
        let fileManager = FileManager.default
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = caches.appendingPathComponent("com.jamesli.usagedock/claude-probe", isDirectory: true)
        let settingsDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        try fileManager.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)

        let settings = settingsDirectory.appendingPathComponent("settings.local.json")
        if !fileManager.fileExists(atPath: settings.path) {
            let data = Data(#"{"disableDeepLinkRegistration":"disable"}"#.utf8)
            try data.write(to: settings, options: .atomic)
        }
        return root
    }

    private static func pathWithClaudeHints(_ existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hints = [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let current = existing?.split(separator: ":").map(String.init) ?? []
        return Array(NSOrderedSet(array: hints + current)).compactMap { $0 as? String }.joined(separator: ":")
    }

    private static func profileEnvironment(_ configurationDirectory: URL?) -> [String: String] {
        var environment = ProviderAccountProcessEnvironment.claude(
            base: ProcessInfo.processInfo.environment,
            configurationDirectory: configurationDirectory
        )
        environment["PATH"] = pathWithClaudeHints(environment["PATH"])
        return environment
    }

    private static func readAvailable(from descriptor: Int32, into data: inout Data) {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(Int(count)))
            } else {
                break
            }
        }
    }

    private static func write(_ text: String, to descriptor: Int32) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(descriptor, baseAddress, buffer.count)
        }
    }

    private static func stop(_ process: Process, terminal descriptor: Int32) {
        write("/exit\r", to: descriptor)
        waitForExit(process, seconds: 0.5)
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
            waitForExit(process, seconds: 0.5)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            waitForExit(process, seconds: 0.5)
        }
        if !process.isRunning {
            process.waitUntilExit()
        }
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            usleep(25_000)
        }
    }
}
