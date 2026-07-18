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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
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
