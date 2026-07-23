import Foundation
import OSLog

/// OpenCode(Go 订阅)本地额度估算。参考 OpenUsage(MIT)的 OpenCode
/// provider:官方暂无用量 API,额度来自扫描本机 `opencode*.db` 里
/// `opencode-go` 的逐消息 `cost`,对照公布的套餐上限($12 / 滚动 5 小时、
/// $30 / UTC 周)。纯本地、只读、无网络;本机之外的消费不可见,
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

    private static let logger = Logger(subsystem: "com.jamesli.usagedock", category: "OpenCodeUsage")

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

        // 只需要一周窗口的数据,再多留一天冗余。
        let cutoffMs = Int((now.timeIntervalSince1970 - 8 * 86_400) * 1000)
        var costs: [(ms: Double, cost: Double)] = []
        for database in databases {
            let sql = """
            SELECT json_group_array(json_array(time_created, json_extract(data,'$.cost')))
            FROM message
            WHERE time_created >= \(cutoffMs)
              AND json_valid(data)
              AND json_extract(data,'$.role') = 'assistant'
              AND json_extract(data,'$.providerID') = 'opencode-go'
              AND json_type(data,'$.cost') IN ('integer','real');
            """
            guard let output = try? await ProcessRunner.run(
                "/usr/bin/sqlite3", arguments: ["-readonly", database, sql]
            ) else { continue }
            costs.append(contentsOf: Self.parseRows(output))
        }
        guard !costs.isEmpty else {
            throw ServiceError.noUsage
        }

        let quota = Self.quota(costs: costs, now: now)
        Self.logger.info("OpenCode quota derived from local database scan")
        return quota
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

    /// 滚动 5 小时消费对 $12 上限 → 主窗口;UTC 周(周一起)消费对 $30 → 副窗口。
    /// 会话重置时间 = 窗口内最早一笔消费 + 5 小时(与 CodexBar/OpenUsage 同口径)。
    static func quota(costs: [(ms: Double, cost: Double)], now: Date) -> ProviderQuota {
        let nowMs = now.timeIntervalSince1970 * 1000
        let fiveHoursMs = 5.0 * 3_600 * 1000

        let sessionStart = nowMs - fiveHoursMs
        let sessionCosts = costs.filter { $0.ms >= sessionStart && $0.ms < nowMs }
        let sessionSpend = sessionCosts.reduce(0) { $0 + $1.cost }
        let sessionResetsAt = sessionCosts.map(\.ms).min()
            .map { Date(timeIntervalSince1970: ($0 + fiveHoursMs) / 1000) }

        var utc = Calendar(identifier: .iso8601)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let weekStart = utc.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let weekStartMs = weekStart.timeIntervalSince1970 * 1000
        let weekEndMs = weekStartMs + 7 * 86_400 * 1000
        let weeklySpend = costs
            .filter { $0.ms >= weekStartMs && $0.ms < weekEndMs }
            .reduce(0) { $0 + $1.cost }

        return ProviderQuota(
            provider: .opencode,
            primary: QuotaWindow(
                usedPercent: min(100, max(0, sessionSpend / sessionCapUSD * 100)),
                windowMinutes: 300,
                resetsAt: sessionResetsAt
            ),
            secondary: QuotaWindow(
                usedPercent: min(100, max(0, weeklySpend / weeklyCapUSD * 100)),
                windowMinutes: 10_080,
                resetsAt: Date(timeIntervalSince1970: weekEndMs / 1000)
            ),
            planName: "Go",
            capturedAt: now
        )
    }
}
