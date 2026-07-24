import Foundation

struct CCUsageService {
    struct Snapshot {
        let daily: DailyUsage
        let history: DailyUsageHistory
    }

    enum ServiceError: LocalizedError {
        case bundledExecutableMissing

        var errorDescription: String? {
            switch self {
            case .bundledExecutableMissing:
                return "TokenRemain 安装不完整：缺少内置 ccusage 组件。请重新安装最新版。"
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
        let data = try await ProcessRunner.run(
            executable.path,
            arguments: Self.commandArguments(since: since),
            timeout: 30
        )
        return try Self.parseSnapshot(data, now: now)
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
            DailyUsage.Agent(id: $0.agent, tokens: $0.totalTokens, estimatedCost: $0.totalCost)
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
    /// shelling out. Days are returned oldest-first; the Claude/Codex split is
    /// keyed off the agent id and defaults to zero for a provider absent that day.
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
    }

    private static func parseHistory(
        _ payload: Response,
        now: Date
    ) -> DailyUsageHistory {
        let days = payload.daily.compactMap { row -> DailyUsageHistory.Day? in
            guard let date = periodFormatter.date(from: row.period) else { return nil }
            var claudeTokens: Int64 = 0
            var claudeCost = 0.0
            var codexTokens: Int64 = 0
            var codexCost = 0.0
            for agent in row.agents ?? [] {
                switch agent.agent.lowercased() {
                case "claude":
                    claudeTokens = agent.totalTokens
                    claudeCost = agent.totalCost
                case "codex":
                    codexTokens = agent.totalTokens
                    codexCost = agent.totalCost
                default:
                    break
                }
            }
            return DailyUsageHistory.Day(
                date: date,
                claudeTokens: claudeTokens,
                claudeCost: claudeCost,
                codexTokens: codexTokens,
                codexCost: codexCost
            )
        }
        .sorted { $0.date < $1.date }
        return DailyUsageHistory(days: days, capturedAt: now)
    }
}
