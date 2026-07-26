import Foundation

struct CCUsageService {
    struct Snapshot {
        let daily: DailyUsage
        let history: DailyUsageHistory
    }

    enum ServiceError: LocalizedError {
        case bundledExecutableMissing
        case helperTimedOut
        case invalidOutput
        case helperFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledExecutableMissing:
                return "TokenRemain 安装不完整：缺少内置 ccusage 组件。请重新安装最新版。"
            case .helperTimedOut:
                return "内置 ccusage 读取超时。请先重试；若持续失败，请重新安装最新版 TokenRemain。"
            case .invalidOutput:
                return "内置 ccusage 返回了无法识别的数据。请重试或重新安装最新版 TokenRemain。"
            case .helperFailed(let detail):
                return "内置 ccusage 无法读取本机日志：\(detail)"
            }
        }
    }

    func fetch() async throws -> DailyUsage {
        try await fetchSnapshot(days: 1).daily
    }

    func fetchHistory(days: Int = 30, now: Date = .now) async throws -> DailyUsageHistory {
        try await fetchSnapshot(days: days, now: now).history
    }

    /// Reads today's totals and multi-day history from one invocation of the
    /// bundled native ccusage helper. `--offline` prevents a local statistics
    /// refresh from ever becoming an npm or pricing-network request.
    func fetchSnapshot(days: Int = 30, now: Date = .now) async throws -> Snapshot {
        let start = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: now) ?? now
        let since = Self.dateFormatter.string(from: start)
        let executable = Self.bundledExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ServiceError.bundledExecutableMissing
        }
        let data: Data
        do {
            data = try await ProcessRunner.run(
                executable.path,
                arguments: Self.commandArguments(since: since),
                timeout: 30
            )
        } catch let error as URLError where error.code == .timedOut {
            throw ServiceError.helperTimedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServiceError.helperFailed(error.localizedDescription)
        }
        do {
            return try Self.parseSnapshot(data, now: now)
        } catch {
            throw ServiceError.invalidOutput
        }
    }

    static func commandArguments(
        since: String,
        timeZone: TimeZone = .current
    ) -> [String] {
        [
            "daily",
            "--json",
            "--by-agent",
            "--offline",
            "--no-color",
            "--timezone", timeZone.identifier,
            "--since", since
        ]
    }

    static func bundledExecutableURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ccusage", isDirectory: false)
    }

    static func parseSnapshot(_ data: Data, now: Date = .now) throws -> Snapshot {
        let payload = try JSONDecoder().decode(Response.self, from: data)
        let today = dateFormatter.string(from: now)
        let row = payload.daily.first(where: { $0.period == today })
        let agents = (row?.agents ?? []).map {
            DailyUsage.Agent(
                id: $0.agent,
                tokens: $0.totalTokens,
                estimatedCost: $0.totalCost,
                unpricedModels: unpricedModels(in: $0)
            )
        }
        return Snapshot(
            daily: DailyUsage(
                date: row?.period ?? today,
                agents: agents,
                capturedAt: now
            ),
            history: parseHistory(payload, now: now)
        )
    }

    /// Decodes a ccusage `daily --by-agent --json` payload into a stacked-per-day
    /// history. Split out from the fetch so it is exercised by unit tests without
    /// shelling out. Days are returned oldest-first and every detected agent is
    /// retained; the UI chooses which series are visible.
    static func parseHistory(_ data: Data, now: Date = .now) throws -> DailyUsageHistory {
        let payload = try JSONDecoder().decode(Response.self, from: data)
        return parseHistory(payload, now: now)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Parses a ccusage `period` (`yyyy-MM-dd`) to local midnight so month/day
    /// axis labels and the day-of-week read in the user's own calendar.
    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private struct Response: Decodable {
        let daily: [Row]
    }
    private struct Row: Decodable {
        let period: String
        let agents: [Agent]?
    }
    private struct Agent: Decodable {
        let agent: String
        let totalTokens: Int64
        let totalCost: Double
        let modelsUsed: [String]?
        let modelBreakdowns: [ModelBreakdown]?
    }
    private struct ModelBreakdown: Decodable {
        let modelName: String
        let cost: Double
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheCreationTokens: Int64
        let cacheReadTokens: Int64

        var totalTokens: Int64 {
            inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        }
    }

    private static func unpricedModels(in agent: Agent) -> [String] {
        // Ollama is intentionally local and has no API list price. For hosted
        // agents, a model row with tokens and a zero cost is indistinguishable
        // from a missing price in ccusage, so present it as unavailable rather
        // than claiming the usage was free.
        guard agent.agent.caseInsensitiveCompare("ollama") != .orderedSame else { return [] }
        let rows = agent.modelBreakdowns ?? []
        let missing = rows
            .filter { $0.totalTokens > 0 && $0.cost == 0 && $0.modelName != "<synthetic>" }
            .map(\.modelName)
        if !missing.isEmpty {
            return Array(Set(missing)).sorted()
        }
        if agent.totalTokens > 0, agent.totalCost == 0, rows.isEmpty {
            return Array(Set(agent.modelsUsed ?? [])).sorted()
        }
        return []
    }

    private static func parseHistory(
        _ payload: Response,
        now: Date
    ) -> DailyUsageHistory {
        let days = payload.daily.compactMap { row -> DailyUsageHistory.Day? in
            guard let date = periodFormatter.date(from: row.period) else { return nil }
            return DailyUsageHistory.Day(
                date: date,
                agents: (row.agents ?? []).map {
                    DailyUsageHistory.Agent(
                        id: $0.agent.lowercased(),
                        tokens: $0.totalTokens,
                        cost: $0.totalCost,
                        unpricedModels: unpricedModels(in: $0)
                    )
                }
            )
        }
        .sorted { $0.date < $1.date }
        return DailyUsageHistory(days: days, capturedAt: now)
    }
}
