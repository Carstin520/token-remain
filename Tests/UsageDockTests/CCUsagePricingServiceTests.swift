import Foundation
import Testing
@testable import UsageDock

@Suite("ccusage public pricing cache")
struct CCUsagePricingServiceTests {
    private actor RequestRecorder {
        private var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            requests.append(request)
        }

        func snapshot() -> [URLRequest] {
            requests
        }
    }

    @Test("A fixed bodyless GET refreshes prices once and produces an offline config")
    func refreshesPublicPricesWithoutUsageData() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = RequestRecorder()
        let payload = try pricingPayload()
        let service = CCUsagePricingService(cacheDirectory: directory) { request in
            await recorder.append(request)
            return (
                payload,
                HTTPURLResponse(
                    url: CCUsagePricingService.sourceURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Content-Length": "\(payload.count)",
                        "ETag": #""pricing-v1""#
                    ]
                )!
            )
        }
        let now = Date(timeIntervalSince1970: 10_000)

        let configURL = try #require(await service.configurationURL(now: now))
        _ = try #require(await service.configurationURL(now: now.addingTimeInterval(60)))

        let requests = await recorder.snapshot()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == CCUsagePricingService.sourceURL)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)

        let root = try jsonObject(at: configURL)
        let defaults = try #require(root["defaults"] as? [String: Any])
        let prices = try #require(defaults["pricingOverrides"] as? [String: Any])
        let opus = try #require(prices["claude-opus-5"] as? [String: Any])
        #expect((opus["inputCostPerToken"] as? NSNumber)?.doubleValue == 0.000005)
        #expect((opus["outputCostPerToken"] as? NSNumber)?.doubleValue == 0.000025)
        #expect((opus["cacheReadInputTokenCost"] as? NSNumber)?.doubleValue == 0.0000005)
    }

    @Test("A failed refresh retains the last validated cache")
    func failedRefreshFallsBackToCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try pricingPayload()
        let initial = CCUsagePricingService(cacheDirectory: directory) { _ in
            (
                payload,
                HTTPURLResponse(
                    url: CCUsagePricingService.sourceURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        let now = Date(timeIntervalSince1970: 20_000)
        let firstURL = try #require(await initial.configurationURL(now: now))
        let firstData = try Data(contentsOf: firstURL)

        let recorder = RequestRecorder()
        let offline = CCUsagePricingService(cacheDirectory: directory) { request in
            await recorder.append(request)
            throw URLError(.notConnectedToInternet)
        }
        let fallbackURL = try #require(
            await offline.configurationURL(
                now: now.addingTimeInterval(CCUsagePricingService.refreshInterval + 1)
            )
        )

        #expect(await recorder.snapshot().count == 1)
        #expect(try Data(contentsOf: fallbackURL) == firstData)
    }

    @Test("A failed first attempt is persisted and not retried before the next day")
    func failedAttemptIsRateLimitedAcrossRelaunch() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 30_000)
        let firstRecorder = RequestRecorder()
        let first = CCUsagePricingService(cacheDirectory: directory) { request in
            await firstRecorder.append(request)
            throw URLError(.notConnectedToInternet)
        }
        #expect(await first.configurationURL(now: now) == nil)
        #expect((await firstRecorder.snapshot()).count == 1)

        let relaunchedRecorder = RequestRecorder()
        let relaunched = CCUsagePricingService(cacheDirectory: directory) { request in
            await relaunchedRecorder.append(request)
            throw URLError(.notConnectedToInternet)
        }
        #expect(await relaunched.configurationURL(now: now.addingTimeInterval(60)) == nil)
        #expect((await relaunchedRecorder.snapshot()).isEmpty)
    }

    @Test("User ccusage settings survive and user prices win field by field")
    func mergesUserConfiguration() throws {
        let publicPrice = CCUsagePricingService.PricingOverride(
            inputCostPerToken: 0.000005,
            outputCostPerToken: 0.000025,
            cacheCreationInputTokenCost: 0.00000625,
            cacheReadInputTokenCost: 0.0000005,
            inputCostPerTokenAbove200kTokens: nil,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            maxInputTokens: 1_000_000,
            fastMultiplier: nil
        )
        let user = Data(#"""
        {
          "defaults": {
            "timezone": "Asia/Shanghai",
            "pricingOverrides": {
              "claude-opus-5": {"outputCostPerToken": 0.123}
            }
          },
          "pi": {"stores": [{"name": "omp", "path": "/private/local/omp"}]}
        }
        """#.utf8)

        let merged = try #require(CCUsagePricingService.mergedRuntimeConfiguration(
            pricingOverrides: ["claude-opus-5": publicPrice],
            userConfiguration: user
        ))
        let root = try #require(
            try JSONSerialization.jsonObject(with: merged) as? [String: Any]
        )
        let defaults = try #require(root["defaults"] as? [String: Any])
        #expect(defaults["timezone"] as? String == "Asia/Shanghai")
        #expect(defaults["mode"] as? String == "calculate")
        let prices = try #require(defaults["pricingOverrides"] as? [String: Any])
        let opus = try #require(prices["claude-opus-5"] as? [String: Any])
        #expect((opus["inputCostPerToken"] as? NSNumber)?.doubleValue == 0.000005)
        #expect((opus["outputCostPerToken"] as? NSNumber)?.doubleValue == 0.123)
        let pi = try #require(root["pi"] as? [String: Any])
        #expect((pi["stores"] as? [[String: Any]])?.first?["name"] as? String == "omp")
    }

    @Test("An explicit user cost mode is preserved")
    func preservesExplicitUserCostMode() throws {
        let price = CCUsagePricingService.PricingOverride(
            inputCostPerToken: 0.000005,
            outputCostPerToken: 0.000025,
            cacheCreationInputTokenCost: nil,
            cacheReadInputTokenCost: nil,
            inputCostPerTokenAbove200kTokens: nil,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            maxInputTokens: nil,
            fastMultiplier: nil
        )
        let user = Data(#"{"defaults":{"mode":"display"}}"#.utf8)
        let merged = try #require(CCUsagePricingService.mergedRuntimeConfiguration(
            pricingOverrides: ["claude-opus-5": price],
            userConfiguration: user
        ))
        let root = try #require(
            try JSONSerialization.jsonObject(with: merged) as? [String: Any]
        )
        let defaults = try #require(root["defaults"] as? [String: Any])
        #expect(defaults["mode"] as? String == "display")
    }

    @Test("Relay and OpenClaw model spellings resolve to the official model price")
    func resolvesRelayModelAliases() throws {
        let official = CCUsagePricingService.PricingOverride(
            inputCostPerToken: 0.000003,
            outputCostPerToken: 0.000015,
            cacheCreationInputTokenCost: 0.00000375,
            cacheReadInputTokenCost: 0.0000003,
            inputCostPerTokenAbove200kTokens: nil,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            maxInputTokens: 200_000,
            fastMultiplier: nil
        )
        let relay = CCUsagePricingService.PricingOverride(
            inputCostPerToken: 0.5,
            outputCostPerToken: 0.5,
            cacheCreationInputTokenCost: nil,
            cacheReadInputTokenCost: nil,
            inputCostPerTokenAbove200kTokens: nil,
            outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil,
            cacheReadInputTokenCostAbove200kTokens: nil,
            maxInputTokens: nil,
            fastMultiplier: nil
        )
        let prices = [
            "claude-sonnet-4-5": official,
            "openrouter/anthropic/claude-sonnet-4-5": relay
        ]

        let match = try #require(CCUsagePricingService.matchedPricing(
            modelName: "[openclaw] openrouter/anthropic/claude-4.5-sonnet-thinking",
            provider: "openrouter",
            pricingOverrides: prices
        ))
        #expect(match.canonicalModel == "claude-sonnet-4-5")
        #expect(match.price == official)
        #expect(abs(match.price.estimatedCost(
            inputTokens: 1_000,
            outputTokens: 500,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        ) - 0.0105) < 0.0000001)

        let expanded = CCUsagePricingService.expandedPricingOverrides(prices)
        #expect(expanded["claude-4.5-sonnet-thinking"] == official)
    }

    @Test("Vendored ccusage recalculates an OpenClaw zero cost from recognized model tokens")
    func openClawZeroCostIntegration() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = root.appending(path: "Vendor/ccusage/20.0.19/darwin-universal/ccusage")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return
        }
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "usagedock-openclaw-price-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sessions = fixture.appending(
            path: "agents/main/sessions",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(#"""
        {"type":"message","message":{"role":"assistant","model":"gpt-5.2","usage":{"input":1000,"output":500,"cost":{"total":0}}},"timestamp":1769753935279}
        """#.utf8).write(to: sessions.appending(path: "fixture.jsonl"))

        let config = fixture.appending(path: "ccusage.json")
        try Data(#"""
        {"defaults":{"mode":"calculate","pricingOverrides":{"gpt-5.2":{"inputCostPerToken":0.000001,"outputCostPerToken":0.000002}}}}
        """#.utf8).write(to: config)
        var environment = ProcessInfo.processInfo.environment
        environment["OPENCLAW_DIR"] = fixture.path
        let data = try await ProcessRunner.run(
            executable.path,
            arguments: [
                "daily", "--json", "--by-agent", "--offline", "--no-color",
                "--timezone", "UTC", "--since", "2026-01-30", "--until", "2026-01-30",
                "--config", config.path
            ],
            environment: environment,
            timeout: 10
        )
        let rootObject = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let daily = try #require(rootObject["daily"] as? [[String: Any]])
        let agents = try #require(daily.first?["agents"] as? [[String: Any]])
        let openClaw = try #require(agents.first { $0["agent"] as? String == "openclaw" })
        let totalCost = try #require((openClaw["totalCost"] as? NSNumber)?.doubleValue)
        #expect(abs(totalCost - 0.002) < 0.000_000_1)
    }

    @Test("Malformed or unsafe price entries are discarded")
    func rejectsUnsafeEntries() throws {
        let data = Data(#"""
        {
          "claude-opus-5": {
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000025
          },
          "negative-price": {
            "input_cost_per_token": -1,
            "output_cost_per_token": 0.1
          },
          "missing-output": {
            "input_cost_per_token": 0.1
          },
          "sample_spec": {
            "input_cost_per_token": "cost per input token",
            "output_cost_per_token": "cost per output token",
            "max_input_tokens": "max input tokens, if specified"
          }
        }
        """#.utf8)

        let values = try CCUsagePricingService.parsePricing(data)
        #expect(values.keys.sorted() == ["claude-opus-5"])
    }

    @Test("Freshness accepts a small clock skew but expires after one day")
    func freshnessPolicy() {
        let fetchedAt = Date(timeIntervalSince1970: 100_000)
        #expect(CCUsagePricingService.isFresh(fetchedAt, now: fetchedAt.addingTimeInterval(60)))
        #expect(CCUsagePricingService.isFresh(fetchedAt, now: fetchedAt.addingTimeInterval(-60)))
        #expect(!CCUsagePricingService.isFresh(
            fetchedAt,
            now: fetchedAt.addingTimeInterval(CCUsagePricingService.refreshInterval)
        ))
    }

    private func pricingPayload() throws -> Data {
        var prices: [String: Any] = [
            "claude-opus-5": [
                "input_cost_per_token": 0.000005,
                "output_cost_per_token": 0.000025,
                "cache_creation_input_token_cost": 0.00000625,
                "cache_read_input_token_cost": 0.0000005,
                "max_input_tokens": 1_000_000
            ],
            "gpt-test": [
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002
            ]
        ]
        for index in 0..<CCUsagePricingService.minimumValidPriceCount {
            prices["fixture-model-\(index)"] = [
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002
            ]
        }
        return try JSONSerialization.data(withJSONObject: prices, options: [.sortedKeys])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ccusage-pricing-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }
}
