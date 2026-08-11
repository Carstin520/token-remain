import Foundation
import OSLog

/// OpenCode(Go 订阅)本地额度估算。参考 OpenUsage(MIT)的 OpenCode
/// provider:官方暂无用量 API,额度来自扫描本机 `opencode*.db` 里
/// `opencode-go` 的逐消息 `cost`,对照公布的套餐上限($12 / 滚动 5 小时、
/// $30 / UTC 周、$60 / 订阅月)。纯本地、只读、无网络;本机之外的消费不可见,
/// 显示值只可能低估。
struct OpenCodeUsageService {
    enum ServiceError: LocalizedError, Sendable {
        case notInstalled
        case noUsage
        case scanFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return L10n.text("service.opencode.not_installed")
            case .noUsage:
                return L10n.text("service.opencode.no_usage")
            case .scanFailed(let detail):
                return L10n.format("service.opencode.scan_failed", detail)
            }
        }
    }

    static let sessionCapUSD: Double = 12
    static let weeklyCapUSD: Double = 30
    static let monthlyCapUSD: Double = 60

    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "OpenCodeUsage")
    private static let anchorCache = OpenCodeAnchorCache()

    var dataDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let custom = environment["OPENCODE_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath).appending(path: "opencode")
        }
        return home.appending(path: ".local/share/opencode")
    }()

    var configurationDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let xdg = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
                .appending(path: "opencode")
        }
        return home.appending(path: ".config/opencode")
    }()

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dataDirectory.path) else {
            throw ServiceError.notInstalled
        }
        // OpenCode 按发布渠道分库(opencode.db / opencode-<channel>.db),全部纳入。
        let databases = ((try? fileManager.contentsOfDirectory(atPath: dataDirectory.path)) ?? [])
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .map { dataDirectory.appending(path: $0).path }
        guard !databases.isEmpty else {
            throw ServiceError.noUsage
        }

        if let providerID = await Self.latestProviderID(in: databases),
           let route = Self.externalRoute(
                providerID: providerID,
                configurationDirectory: configurationDirectory,
                dataDirectory: dataDirectory
           ) {
            return try await HostAppQuotaRoutingService().fetchExternal(route)
        }

        // Current monthly window is at most 31 days. Forty days leaves enough
        // margin for an anchored billing boundary without materializing the
        // full message history; a separate MIN query discovers that anchor.
        let cutoffMs = Int((now.timeIntervalSince1970 - 40 * 86_400) * 1000)
        var costs: [(ms: Double, cost: Double)] = []
        var earliestMs: Double?
        for database in databases {
            let baseFilter = """
            json_valid(data)
              AND json_extract(data,'$.role') = 'assistant'
              AND json_extract(data,'$.providerID') = 'opencode-go'
              AND json_type(data,'$.cost') IN ('integer','real')
            """
            let cachedAnchor = await Self.anchorCache.lookup(database)
            switch cachedAnchor {
            case .resolved(let value):
                if let value { earliestMs = min(earliestMs ?? value, value) }
            case .unresolved:
                let earliestSQL = """
                SELECT MIN(CAST(COALESCE(json_extract(data,'$.time.created'), time_created) AS INTEGER))
                FROM message
                WHERE \(baseFilter);
                """
                do {
                    let output = try await ProcessRunner.run(
                        "/usr/bin/sqlite3", arguments: ["-readonly", database, earliestSQL]
                    )
                    let value = Self.parseScalar(output)
                    // An empty successful MIN is stable for this app run. A
                    // transient sqlite error is not: leave it unresolved so a
                    // later refresh can recover the real billing anchor.
                    await Self.anchorCache.store(value, for: database)
                    if let value { earliestMs = min(earliestMs ?? value, value) }
                } catch {
                    Self.logger.debug("OpenCode anchor lookup will retry after sqlite failure")
                }
            }
            let coarseCutoffMs = cutoffMs - 2 * 86_400 * 1000
            let sql = """
            SELECT json_group_array(json_array(
                CAST(COALESCE(json_extract(data,'$.time.created'), time_created) AS INTEGER),
                json_extract(data,'$.cost')
            ))
            FROM message
            WHERE time_created >= \(coarseCutoffMs)
              AND CAST(COALESCE(json_extract(data,'$.time.created'), time_created) AS INTEGER) >= \(cutoffMs)
              AND \(baseFilter);
            """
            guard let output = try? await ProcessRunner.run(
                "/usr/bin/sqlite3", arguments: ["-readonly", database, sql]
            ) else { continue }
            costs.append(contentsOf: Self.parseRows(output))
        }
        guard !costs.isEmpty else {
            throw ServiceError.noUsage
        }

        let quota = Self.quota(costs: costs, now: now, anchorMs: earliestMs)
        Self.logger.info("OpenCode quota derived from local database scan")
        return quota
    }

    /// The newest assistant message is the best local evidence of the provider
    /// OpenCode actually used. Configuration alone is insufficient because a
    /// user can switch models/providers per session.
    static func latestProviderID(in databases: [String]) async -> String? {
        var latest: (timestamp: Double, providerID: String)?
        let sql = """
        SELECT json_array(
          CAST(COALESCE(json_extract(data,'$.time.created'), time_created) AS INTEGER),
          json_extract(data,'$.providerID')
        )
        FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_type(data,'$.providerID') = 'text'
        ORDER BY CAST(COALESCE(json_extract(data,'$.time.created'), time_created) AS INTEGER) DESC
        LIMIT 1;
        """
        for database in databases {
            guard let output = try? await ProcessRunner.run(
                "/usr/bin/sqlite3", arguments: ["-readonly", database, sql]
            ), let candidate = parseProviderRouteRow(output) else { continue }
            if latest.map({ candidate.timestamp > $0.timestamp }) ?? true {
                latest = candidate
            }
        }
        return latest?.providerID
    }

    static func parseProviderRouteRow(_ data: Data) -> (timestamp: Double, providerID: String)? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let row = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              row.count >= 2,
              let timestamp = (row[0] as? NSNumber)?.doubleValue,
              let providerID = (row[1] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            return nil
        }
        return (timestamp, providerID)
    }

    static func providerBaseURL(
        providerID: String,
        configurationDirectory: URL
    ) -> URL? {
        providerRouteConfiguration(
            providerID: providerID,
            configurationDirectory: configurationDirectory
        ).baseURL
    }

    struct ProviderRouteConfiguration: Equatable, Sendable {
        let baseURL: URL?
        let hasBaseURLOverride: Bool
    }

    static func providerRouteConfiguration(
        providerID: String,
        configurationDirectory: URL
    ) -> ProviderRouteConfiguration {
        var hasBaseURLOverride = false
        for name in ["opencode.json", "opencode.jsonc"] {
            let url = configurationDirectory.appending(path: name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let data = strippingJSONComments(text).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let providers = root["provider"] as? [String: Any],
                  let provider = providers[providerID] as? [String: Any] else { continue }
            let options = provider["options"] as? [String: Any]
            let optionHasOverride = options?.keys.contains("baseURL") == true
                || options?.keys.contains("baseUrl") == true
            let providerHasOverride = provider.keys.contains("baseURL")
                || provider.keys.contains("baseUrl")
            guard optionHasOverride || providerHasOverride else { continue }
            hasBaseURLOverride = true
            let raw = (options?["baseURL"] as? String)
                ?? (options?["baseUrl"] as? String)
                ?? (provider["baseURL"] as? String)
                ?? (provider["baseUrl"] as? String)
            if let raw,
               let baseURL = HostAppQuotaRouteDetector.normalizedBaseURL(raw) {
                return ProviderRouteConfiguration(
                    baseURL: baseURL,
                    hasBaseURLOverride: true
                )
            }
        }
        return ProviderRouteConfiguration(
            baseURL: nil,
            hasBaseURLOverride: hasBaseURLOverride
        )
    }

    static func externalRoute(
        providerID: String,
        configurationDirectory: URL,
        dataDirectory: URL
    ) -> HostAppQuotaRoute? {
        let configuration = providerRouteConfiguration(
            providerID: providerID,
            configurationDirectory: configurationDirectory
        )
        let isOpenCodeGo = providerID.caseInsensitiveCompare("opencode-go") == .orderedSame
        if isOpenCodeGo,
           (!configuration.hasBaseURLOverride
                || configuration.baseURL.map(isOfficialOpenCodeURL) == true) {
            return nil
        }
        return HostAppQuotaRouteDetector.externalRoute(
            hostProvider: .opencode,
            providerID: configuration.hasBaseURLOverride && configuration.baseURL == nil
                ? "configured-relay"
                : providerID,
            baseURL: configuration.baseURL,
            credential: providerCredential(providerID: providerID, dataDirectory: dataDirectory)
        )
    }

    static func isOfficialOpenCodeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "opencode.ai" || host.hasSuffix(".opencode.ai")
    }

    static func providerCredential(providerID: String, dataDirectory: URL) -> String? {
        let url = dataDirectory.appending(path: "auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[providerID] as? [String: Any] else { return nil }
        for key in ["key", "apiKey", "token"] {
            let value = (entry[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// JSONC support used only to locate a provider base URL. Strings are kept
    /// byte-for-byte while line/block comments are removed.
    static func strippingJSONComments(_ text: String) -> String {
        enum State { case normal, string, lineComment, blockComment }
        var state = State.normal
        var result = ""
        var index = text.startIndex
        var escaped = false
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            let following = next < text.endIndex ? text[next] : nil
            switch state {
            case .normal:
                if character == "\"" {
                    state = .string
                    result.append(character)
                } else if character == "/", following == "/" {
                    state = .lineComment
                    index = next
                } else if character == "/", following == "*" {
                    state = .blockComment
                    index = next
                } else {
                    result.append(character)
                }
            case .string:
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    state = .normal
                }
            case .lineComment:
                if character.isNewline {
                    state = .normal
                    result.append(character)
                }
            case .blockComment:
                if character == "*", following == "/" {
                    state = .normal
                    index = next
                } else if character.isNewline {
                    result.append(character)
                }
            }
            index = text.index(after: index)
        }
        return result
    }

    /// sqlite 输出是一行 JSON 数组的数组:`[[time_created, cost], …]`。
    static func parseRows(_ data: Data) -> [(ms: Double, cost: Double)] {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let rows = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard row.count >= 2,
                  let ms = (row[0] as? NSNumber)?.doubleValue,
                  let cost = (row[1] as? NSNumber)?.doubleValue,
                  cost >= 0 else {
                return nil
            }
            return (ms, cost)
        }
    }

    static func parseScalar(_ data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let value = Double(text), value.isFinite, value > 0 else {
            return nil
        }
        return value
    }

    /// 滚动 5 小时消费对 $12 上限 → 主窗口;UTC 周(周一起)消费对 $30 → 副窗口。
    /// 会话重置时间 = 窗口内最早一笔消费 + 5 小时(与 CodexBar/OpenUsage 同口径)。
    static func quota(
        costs: [(ms: Double, cost: Double)],
        now: Date,
        anchorMs: Double? = nil
    ) -> ProviderQuota {
        let nowMs = now.timeIntervalSince1970 * 1000
        let fiveHoursMs = 5.0 * 3_600 * 1000

        let sessionStart = nowMs - fiveHoursMs
        let sessionCosts = costs.filter { $0.ms >= sessionStart && $0.ms < nowMs }
        let sessionSpend = sessionCosts.reduce(0) { $0 + $1.cost }
        let sessionResetsAt = sessionCosts.map(\.ms).min().map {
            Date(timeIntervalSince1970: ($0 + fiveHoursMs) / 1000)
        }

        var utc = Calendar(identifier: .iso8601)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let weekStart = utc.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let weekStartMs = weekStart.timeIntervalSince1970 * 1000
        let weekEndMs = weekStartMs + 7 * 86_400 * 1000
        let weeklySpend = costs
            .filter { $0.ms >= weekStartMs && $0.ms < weekEndMs }
            .reduce(0) { $0 + $1.cost }

        let month = monthBounds(nowMs: nowMs, anchorMs: anchorMs ?? costs.map(\.ms).min())
        let monthlySpend = costs
            .filter { $0.ms >= month.startMs && $0.ms < month.endMs }
            .reduce(0) { $0 + $1.cost }
        let monthlyMinutes = max(1, Int((month.endMs - month.startMs) / 60_000))

        return ProviderQuota(
            provider: .opencode,
            primary: QuotaWindow(
                usedPercent: min(100, max(0, sessionSpend / sessionCapUSD * 100)),
                windowMinutes: 300,
                resetsAt: sessionResetsAt,
                remainingBalance: QuotaBalance(
                    amount: max(0, sessionCapUSD - sessionSpend),
                    currencyCode: "USD"
                )
            ),
            secondary: QuotaWindow(
                usedPercent: min(100, max(0, weeklySpend / weeklyCapUSD * 100)),
                windowMinutes: 10_080,
                resetsAt: Date(timeIntervalSince1970: weekEndMs / 1000),
                remainingBalance: QuotaBalance(
                    amount: max(0, weeklyCapUSD - weeklySpend),
                    currencyCode: "USD"
                )
            ),
            planName: "Go",
            capturedAt: now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "opencode_monthly",
                    displayName: "Monthly",
                    window: QuotaWindow(
                        usedPercent: min(100, max(0, monthlySpend / monthlyCapUSD * 100)),
                        windowMinutes: monthlyMinutes,
                        resetsAt: Date(timeIntervalSince1970: month.endMs / 1000),
                        remainingBalance: QuotaBalance(
                            amount: max(0, monthlyCapUSD - monthlySpend),
                            currencyCode: "USD"
                        )
                    )
                )
            ]
        )
    }

    /// Returns the UTC billing month containing now. When available, the first
    /// OpenCode Go usage pins the day/time boundary; otherwise calendar-month
    /// boundaries are used.
    static func monthBounds(nowMs: Double, anchorMs: Double?) -> (startMs: Double, endMs: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: nowMs / 1000)

        guard let anchorMs else {
            let interval = calendar.dateInterval(of: .month, for: now)
            let start = interval?.start ?? now
            let end = interval?.end ?? calendar.date(byAdding: .month, value: 1, to: start) ?? now
            return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
        }

        let anchor = Date(timeIntervalSince1970: anchorMs / 1000)
        let anchorParts = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor)
        let nowParts = calendar.dateComponents([.year, .month], from: now)

        func boundary(year: Int, month: Int) -> Date {
            let startOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            let range = calendar.range(of: .day, in: .month, for: startOfMonth) ?? 1..<29
            var parts = DateComponents(
                year: year,
                month: month,
                day: min(anchorParts.day ?? 1, range.count),
                hour: anchorParts.hour,
                minute: anchorParts.minute,
                second: anchorParts.second,
                nanosecond: anchorParts.nanosecond
            )
            parts.timeZone = calendar.timeZone
            return calendar.date(from: parts) ?? startOfMonth
        }

        let year = nowParts.year ?? 1970
        let month = nowParts.month ?? 1
        var start = boundary(year: year, month: month)
        if start > now {
            let previous = calendar.date(byAdding: .month, value: -1, to: start) ?? start
            let previousParts = calendar.dateComponents([.year, .month], from: previous)
            start = boundary(year: previousParts.year ?? year, month: previousParts.month ?? month)
        }
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let nextParts = calendar.dateComponents([.year, .month], from: next)
        let end = boundary(year: nextParts.year ?? year, month: nextParts.month ?? month)
        return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
    }
}

private actor OpenCodeAnchorCache {
    enum Lookup: Sendable {
        case unresolved
        case resolved(Double?)
    }

    private var resolvedPaths = Set<String>()
    private var values: [String: Double] = [:]

    func lookup(_ path: String) -> Lookup {
        resolvedPaths.contains(path) ? .resolved(values[path]) : .unresolved
    }

    func store(_ value: Double?, for path: String) {
        resolvedPaths.insert(path)
        values[path] = value
    }
}
