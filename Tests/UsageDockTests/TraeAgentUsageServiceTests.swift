import Foundation
import Testing
@testable import UsageDock

struct TraeAgentUsageServiceTests {
    @Test("Trae trajectories expose only token counters and use official-model pricing aliases")
    func parsesAllowlistedUsageAndPricesRelayModel() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-29T12:00:00Z"))
        let price = testPrice(input: 3e-6, output: 15e-6)
        let data = Data(#"""
        {
          "provider": "openrouter/anthropic",
          "model": "anthropic/claude-4.5-sonnet-thinking",
          "agent": {"system_prompt": "SECRET SYSTEM PROMPT"},
          "llm_interactions": [{
            "timestamp": "2026-07-29T10:15:30.123Z",
            "request": {"messages": [{"content": "SECRET SOURCE CODE"}]},
            "response": {
              "content": "SECRET RESPONSE",
              "usage": {
                "input_tokens": 1000,
                "output_tokens": 200,
                "cache_creation_input_tokens": 100,
                "cache_read_input_tokens": 500
              }
            }
          }]
        }
        """#.utf8)

        let snapshot = TraeAgentUsageService.parse(
            files: [(URL(fileURLWithPath: "/tmp/trajectory.json"), data)],
            pricingOverrides: ["claude-sonnet-4-5": price],
            now: now,
            calendar: utcCalendar
        )

        let agent = try #require(snapshot.daily.agents.first)
        #expect(agent.id == "trae-agent")
        #expect(agent.tokens == 1_800)
        #expect(abs(agent.estimatedCost - 0.006525) < 0.000_000_1)
        #expect(agent.unpricedModels.isEmpty)
        #expect(snapshot.history.days.count == 1)
    }

    @Test("Unknown hosted models are unavailable, while local Ollama use is intentionally zero")
    func missingPriceVersusLocalModel() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-29T12:00:00Z"))
        let hosted = trajectory(
            timestamp: "2026-07-29T09:00:00Z",
            provider: "custom-relay",
            model: "future-model",
            input: 10,
            output: 2
        )
        let local = trajectory(
            timestamp: "2026-07-29T10:00:00Z",
            provider: "ollama",
            model: "qwen-local",
            input: 20,
            output: 3
        )

        let snapshot = TraeAgentUsageService.parse(
            files: [
                (URL(fileURLWithPath: "/tmp/hosted.json"), hosted),
                (URL(fileURLWithPath: "/tmp/local.json"), local)
            ],
            pricingOverrides: [:],
            now: now,
            calendar: utcCalendar
        )
        let agent = try #require(snapshot.daily.agents.first)
        #expect(agent.tokens == 35)
        #expect(agent.estimatedCost == 0)
        #expect(agent.unpricedModels == ["future-model"])
    }

    @Test("The same trajectory file is never counted twice")
    func deduplicatesFilePaths() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-29T12:00:00Z"))
        let data = trajectory(
            timestamp: "2026-07-29T10:00:00Z",
            provider: "openai",
            model: "gpt-5",
            input: 7,
            output: 3
        )
        let url = URL(fileURLWithPath: "/tmp/repeated.json")
        let snapshot = TraeAgentUsageService.parse(
            files: [(url, data), (url, data)],
            pricingOverrides: ["gpt-5": testPrice(input: 1e-6, output: 2e-6)],
            now: now,
            calendar: utcCalendar
        )
        #expect(snapshot.daily.agents.first?.tokens == 10)
    }

    @Test("Trajectory directories persist without copying trajectory content")
    func trajectoryDirectoryStore() throws {
        let suite = "TraeAgentUsageServiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory
            .appending(path: "trae-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let automatic = home.appending(path: "trajectories", directoryHint: .isDirectory)
        let selected = home.appending(path: "project/private-trajectories", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: automatic, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TraeAgentTrajectoryStore(defaults: defaults, home: home)

        store.add(selected)
        #expect(store.availableDirectories.map(\.path) == [selected.path, automatic.path].sorted())
        #expect(defaults.stringArray(forKey: TraeAgentTrajectoryStore.defaultsKey) == [selected.path])
        store.remove(selected)
        #expect(store.configuredDirectories.isEmpty)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func trajectory(
        timestamp: String,
        provider: String,
        model: String,
        input: Int,
        output: Int
    ) -> Data {
        Data(#"""
        {
          "llm_interactions": [{
            "timestamp": "\#(timestamp)",
            "provider": "\#(provider)",
            "model": "\#(model)",
            "response": {"usage": {"input_tokens": \#(input), "output_tokens": \#(output)}}
          }]
        }
        """#.utf8)
    }

    private func testPrice(
        input: Double,
        output: Double
    ) -> CCUsagePricingService.PricingOverride {
        .init(
            inputCostPerToken: input,
            outputCostPerToken: output,
            cacheCreationInputTokenCost: nil,
            cacheReadInputTokenCost: nil,
            inputCostPerTokenAbove200kTokens: nil,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            maxInputTokens: nil,
            fastMultiplier: nil
        )
    }
}
