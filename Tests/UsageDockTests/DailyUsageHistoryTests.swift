import Foundation
import Testing
@testable import UsageDock

@Suite("Daily usage history")
struct DailyUsageHistoryTests {
    private func payload(_ rows: String) -> Data {
        Data("{\"daily\":[\(rows)]}".utf8)
    }

    @Test("Parses every per-day agent from ccusage by-agent JSON")
    func parsesSplit() throws {
        let data = payload("""
        {"period":"2026-07-18","agents":[
            {"agent":"claude","totalTokens":300,"totalCost":1.5},
            {"agent":"codex","totalTokens":100,"totalCost":0.5},
            {"agent":"gemini","totalTokens":40,"totalCost":0.1}
        ]},
        {"period":"2026-07-19","agents":[
            {"agent":"codex","totalTokens":250,"totalCost":2.0},
            {"agent":"claude","totalTokens":50,"totalCost":0.25}
        ]}
        """)

        let history = try CCUsageService.parseHistory(data)
        #expect(history.days.count == 2)

        // Oldest-first ordering regardless of input / agent order.
        let first = history.days[0]
        #expect(first.claudeTokens == 300)
        #expect(first.codexTokens == 100)
        #expect(first.totalTokens == 440)
        #expect(first.totalCost == 2.1)
        #expect(first.tokens(forAgentID: "gemini") == 40)

        let second = history.days[1]
        #expect(second.claudeTokens == 50)
        #expect(second.codexTokens == 250)
        #expect(second.date > first.date)
    }

    @Test("One offline ccusage report supplies both today and history")
    func parsesUnifiedOfflineSnapshot() throws {
        let data = payload("""
        {"period":"2026-07-23","agents":[
            {"agent":"claude","totalTokens":100,"totalCost":0.5}
        ]},
        {"period":"2026-07-24","agents":[
            {"agent":"claude","totalTokens":300,"totalCost":1.5},
            {"agent":"codex","totalTokens":200,"totalCost":1.0}
        ]}
        """)
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 24
        components.hour = 12
        let now = try #require(Calendar.current.date(from: components))

        let snapshot = try CCUsageService.parseSnapshot(data, now: now)

        #expect(snapshot.daily.date == "2026-07-24")
        #expect(snapshot.daily.agents.reduce(0) { $0 + $1.tokens } == 500)
        #expect(snapshot.history.days.count == 2)
        #expect(snapshot.history.days.last?.totalTokens == 500)
    }

    @Test("A token-bearing model without a price is unavailable, never free")
    func preservesMissingPrice() throws {
        let data = payload("""
        {"period":"2026-07-26","agents":[{
            "agent":"claude",
            "totalTokens":99960288,
            "totalCost":0,
            "modelsUsed":["claude-opus-5"],
            "modelBreakdowns":[{
                "modelName":"claude-opus-5",
                "cost":0,
                "inputTokens":9736,
                "outputTokens":284382,
                "cacheCreationTokens":1701645,
                "cacheReadTokens":97964525
            }]
        }]}
        """)
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 26
        components.hour = 12
        let now = try #require(Calendar.current.date(from: components))

        let snapshot = try CCUsageService.parseSnapshot(data, now: now)
        let agent = try #require(snapshot.daily.agents.first)
        let insights = UsageInsights(claude: nil, codex: nil, daily: snapshot.daily)

        #expect(agent.tokens == 99_960_288)
        #expect(agent.unpricedModels == ["claude-opus-5"])
        #expect(snapshot.history.days.first?.agents.first?.models.first?.id == "claude-opus-5")
        #expect(snapshot.history.days.first?.agents.first?.models.first?.cacheTokens == 99_666_170)
        #expect(insights.totalCost == nil)
        #expect(insights.unpricedModels == ["claude-opus-5"])
        #expect(snapshot.history.days.first?.totalCost == nil)
    }

    @Test("One missing model makes a mixed provider total incomplete")
    func mixedModelsRemainIncomplete() throws {
        let data = payload("""
        {"period":"2026-07-25","agents":[{
            "agent":"claude",
            "totalTokens":200,
            "totalCost":1.5,
            "modelsUsed":["claude-fable-5","claude-opus-5"],
            "modelBreakdowns":[
                {"modelName":"claude-fable-5","cost":1.5,"inputTokens":10,"outputTokens":10,"cacheCreationTokens":10,"cacheReadTokens":10},
                {"modelName":"claude-opus-5","cost":0,"inputTokens":40,"outputTokens":40,"cacheCreationTokens":40,"cacheReadTokens":40}
            ]
        }]}
        """)

        let day = try #require(try CCUsageService.parseHistory(data).days.first)
        #expect(day.knownTotalCost == 1.5)
        #expect(day.totalCost == nil)
        #expect(day.unpricedModels == ["claude-opus-5"])
    }

    @Test("Bundled ccusage stays offline while accepting an app-owned price config")
    func bundledInvocationIsOffline() {
        let configURL = URL(fileURLWithPath: "/tmp/tokenremain-ccusage-pricing.json")
        let arguments = CCUsageService.commandArguments(
            since: "2026-07-01",
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            pricingConfigurationURL: configURL
        )

        #expect(arguments.first == "daily")
        #expect(arguments.contains("--offline"))
        #expect(arguments.contains("--by-agent"))
        #expect(arguments.contains("Asia/Shanghai"))
        #expect(arguments.contains("--config"))
        #expect(arguments.contains(configURL.path))
        #expect(!arguments.joined(separator: " ").contains("npx"))
        #expect(!arguments.joined(separator: " ").contains("latest"))
    }

    @Test("A provider absent on a day defaults to zero, no fabricated value")
    func absentProviderIsZero() throws {
        let data = payload("""
        {"period":"2026-07-20","agents":[
            {"agent":"claude","totalTokens":500,"totalCost":3.0}
        ]}
        """)

        let day = try #require(try CCUsageService.parseHistory(data).days.first)
        #expect(day.claudeTokens == 500)
        #expect(day.codexTokens == 0)
        #expect(day.codexCost == 0)
        #expect(day.tokens(for: .codex) == 0)
        #expect(day.cost(for: .claude) == 3.0)
    }

    @Test("Trend provider selection supports both, either, and neither series")
    func selectedTrendTotals() throws {
        let data = payload("""
        {"period":"2026-07-20","agents":[
            {"agent":"claude","totalTokens":300,"totalCost":1.5},
            {"agent":"codex","totalTokens":100,"totalCost":0.5}
        ]}
        """)
        let day = try #require(try CCUsageService.parseHistory(data).days.first)

        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .tokens,
            visibleAgentIDs: ["claude", "codex"]
        ) == 400)
        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .tokens,
            visibleAgentIDs: ["codex"]
        ) == 100)
        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .cost,
            visibleAgentIDs: ["claude"]
        ) == 1.5)
        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .tokens,
            visibleAgentIDs: []
        ) == 0)
    }

    @Test("A newly discovered agent can be selected without a code change")
    func dynamicAgentSelection() throws {
        let data = payload("""
        {"period":"2026-07-20","agents":[
            {"agent":"gemini","totalTokens":275,"totalCost":0.75}
        ]}
        """)
        let day = try #require(try CCUsageService.parseHistory(data).days.first)
        #expect(UsageTrendChart.selectedTotal(
            day,
            metric: .tokens,
            visibleAgentIDs: ["gemini"]
        ) == 275)
        #expect(UsageInsights.displayName(for: "gemini") == "Gemini")
    }

    @Test("An empty successful report is no-usage, not an endless loading state")
    func emptyReportState() throws {
        let snapshot = try CCUsageService.parseSnapshot(payload(""))
        #expect(snapshot.daily.agents.isEmpty)
        #expect(UsageStore.localUsageStatus(for: snapshot.daily) == .empty)
    }

    @Test("Pre-dynamic history cache decodes without losing Claude and Codex")
    func legacyCacheMigration() throws {
        let json = """
        {
          "days": [{
            "date": 0,
            "claudeTokens": 300,
            "claudeCost": 1.5,
            "codexTokens": 100,
            "codexCost": 0.5
          }],
          "capturedAt": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let history = try decoder.decode(DailyUsageHistory.self, from: Data(json.utf8))
        let day = try #require(history.days.first)
        #expect(day.tokens(forAgentID: "claude") == 300)
        #expect(day.tokens(forAgentID: "codex") == 100)
        #expect(day.totalCost == 2)
    }

    @Test("Dynamic history cache round-trips unknown agents")
    func dynamicCacheRoundTrip() throws {
        let history = DailyUsageHistory(
            days: [
                .init(
                    date: Date(timeIntervalSince1970: 1_000),
                    agents: [.init(id: "gemini", tokens: 123, cost: 0.45)]
                )
            ],
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        let decoded = try JSONDecoder().decode(
            DailyUsageHistory.self,
            from: JSONEncoder().encode(history)
        )
        #expect(decoded.days.first?.tokens(forAgentID: "gemini") == 123)
        #expect(decoded.days.first?.cost(forAgentID: "gemini") == 0.45)
    }

    @Test("Model history is bounded to named rows plus an aggregated tail")
    func boundedModelHistory() {
        let rows = (0..<10).map { index in
            return DailyUsageHistory.ModelUsage(
                id: "model-\(index)",
                inputTokens: Int64(100 - index),
                outputTokens: 1,
                cacheTokens: 0,
                cost: Double(index) / 10
            )
        }
        let bounded = DailyUsageHistory.boundedModels(rows)
        #expect(bounded.count == 8)
        #expect(bounded.last?.id == "other")
        #expect(bounded.last?.constituentCount == 3)
        #expect(bounded.reduce(0) { $0 + $1.totalTokens } == rows.reduce(0) { $0 + $1.totalTokens })
    }

    @Test("Pinned-day projection ranks five models and keeps the tail as Other")
    func modelBreakdownProjection() {
        let models: [DailyUsageHistory.ModelUsage] = (0..<7).map { index in
            let inputTokens = Int64((7 - index) * 100)
            let outputTokens = Int64(index)
            return DailyUsageHistory.ModelUsage(
                id: "claude-model-\(index)",
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheTokens: 0,
                cost: Double(7 - index)
            )
        }
        let day = DailyUsageHistory.Day(
            date: Date(timeIntervalSince1970: 1_000),
            agents: [
                .init(
                    id: "claude",
                    tokens: 2_821,
                    cost: 28,
                    unpricedModels: ["claude-model-6"],
                    models: models
                )
            ]
        )
        let breakdown = TrendDayModelBreakdown.make(
            day: day,
            agentIDs: ["claude"],
            metric: .tokens
        )
        let rows = breakdown.groups.first?.rows ?? []
        #expect(rows.count == 6)
        #expect(rows.last?.id == "other")
        #expect(rows.last?.constituentCount == 2)
        #expect(rows.last?.isUnpriced == true)
        let displayedTotal = rows.reduce(Int64(0)) { $0 + $1.totalTokens }
        let sourceTotal = models.reduce(Int64(0)) { $0 + $1.totalTokens }
        #expect(displayedTotal == sourceTotal)
    }

    @Test("Older cached agents decode without model detail")
    func preModelCacheMigration() throws {
        let json = #"{"id":"claude","tokens":123,"cost":0.5}"#
        let agent = try JSONDecoder().decode(
            DailyUsageHistory.Agent.self,
            from: Data(json.utf8)
        )
        #expect(agent.models.isEmpty)
    }

    @Test("Rows with unparseable periods are dropped rather than guessed")
    func dropsBadPeriods() throws {
        let data = payload("""
        {"period":"not-a-date","agents":[{"agent":"claude","totalTokens":1,"totalCost":0.1}]},
        {"period":"2026-07-20","agents":[{"agent":"claude","totalTokens":2,"totalCost":0.2}]}
        """)

        let history = try CCUsageService.parseHistory(data)
        #expect(history.days.count == 1)
        #expect(history.days.first?.claudeTokens == 2)
    }

    @Test("Nice axis ceiling rounds a peak up to 1/2/2.5/5/10 x 10^n")
    func niceCeiling() {
        #expect(UsageTrendChart.niceCeiling(0) == 1)
        #expect(UsageTrendChart.niceCeiling(1_200_000) == 2_000_000)
        #expect(UsageTrendChart.niceCeiling(4.5) == 5)
        #expect(UsageTrendChart.niceCeiling(2.3) == 2.5)
        #expect(UsageTrendChart.niceCeiling(900) == 1_000)
    }

    @Test("Compact axis token labels stay short enough for the y gutter")
    func compactAxisTokens() {
        #expect(UsageTrendChart.compactAxisTokens(1_000_000_000) == "1.0B")
        #expect(UsageTrendChart.compactAxisTokens(750_000_000) == "750M")
        #expect(UsageTrendChart.compactAxisTokens(1_200_000) == "1.2M")
        #expect(UsageTrendChart.compactAxisTokens(500_000) == "500K")
        #expect(UsageTrendChart.compactAxisTokens(250) == "250")
    }

    @Test("Day labels read in month/day form")
    func dayLabels() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 9
        let date = Calendar.current.date(from: components)!
        #expect(UsageTrendChart.dayMonthLabel(date) == "7/9")
        #expect(UsageTrendChart.fullDayLabel(date) == "7月9日")
    }
}
