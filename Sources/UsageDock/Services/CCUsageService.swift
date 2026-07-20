import Foundation

struct CCUsageService {
    func fetch() async throws -> DailyUsage {
        let date = Self.dateFormatter.string(from: .now)
        let command = "npx --yes ccusage@latest daily --json --by-agent --since \(date)"
        let data = try await ProcessRunner.run("/bin/zsh", arguments: ["-lic", command])
        let payload = try JSONDecoder().decode(Response.self, from: data)
        let row = payload.daily.first
        let agents = (row?.agents ?? []).map {
            DailyUsage.Agent(id: $0.agent, tokens: $0.totalTokens, estimatedCost: $0.totalCost)
        }
        return DailyUsage(date: row?.period ?? date, agents: agents, capturedAt: .now)
    }

    /// Fetches the last `days` calendar days of per-agent usage so the Trends
    /// section can plot a real stacked history. Mirrors `fetch()`'s invocation
    /// style but widens the `--since` window instead of pinning it to today.
    func fetchHistory(days: Int = 30, now: Date = .now) async throws -> DailyUsageHistory {
        let start = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: now) ?? now
        let since = Self.dateFormatter.string(from: start)
        let command = "npx --yes ccusage@latest daily --json --by-agent --since \(since)"
        let data = try await ProcessRunner.run("/bin/zsh", arguments: ["-lic", command])
        return try Self.parseHistory(data, now: now)
    }

    /// Decodes a ccusage `daily --by-agent --json` payload into a stacked-per-day
    /// history. Split out from the fetch so it is exercised by unit tests without
    /// shelling out. Days are returned oldest-first; the Claude/Codex split is
    /// keyed off the agent id and defaults to zero for a provider absent that day.
    static func parseHistory(_ data: Data, now: Date = .now) throws -> DailyUsageHistory {
        let payload = try JSONDecoder().decode(Response.self, from: data)
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
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
}
