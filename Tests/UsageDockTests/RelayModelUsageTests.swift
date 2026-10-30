import Foundation
import Testing
@testable import UsageDock

@Suite("Relay model usage")
struct RelayModelUsageTests {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    @Test("Per-period rows sum into one row per model, largest first")
    func aggregatesRows() {
        func row(_ model: String, _ input: Int64, _ output: Int64, _ cents: Double?) -> ProviderModelUsage {
            ProviderModelUsage(
                model: model, inputTokens: input, outputTokens: output,
                cacheWriteTokens: 0, cacheReadTokens: 0, costCents: cents
            )
        }
        let rows = ProviderModelUsage.aggregated([
            row("gpt-5", 100, 50, 10),
            row("claude-4.5-sonnet", 80, 20, nil),
            row(" gpt-5 ", 30, 0, 5),
            row("", 999, 0, nil),
            row("idle", 0, 0, nil)
        ])
        #expect(rows.map(\.model) == ["gpt-5", "claude-4.5-sonnet"])
        #expect(rows[0].totalTokens == 180)
        #expect(rows[0].costCents == 15)
        #expect(rows[1].costCents == nil)
    }

    @Test("OpenRouter activity is only requested for management keys")
    func managementKeyDetection() {
        #expect(OpenRouterActivityParser.isManagementKey(Data(#"{"data":{"is_management_key":true}}"#.utf8)))
        #expect(OpenRouterActivityParser.isManagementKey(Data(#"{"data":{"is_provisioning_key":true}}"#.utf8)))
        #expect(!OpenRouterActivityParser.isManagementKey(Data(#"{"data":{"is_management_key":false}}"#.utf8)))
        #expect(!OpenRouterActivityParser.isManagementKey(nil))
    }

    @Test("OpenRouter daily activity sums per model with USD cost")
    func parsesOpenRouterActivity() throws {
        let data = Data("""
        {"data": [
          {"date": "2026-10-01", "model": "anthropic/claude-sonnet-4.5", "prompt_tokens": 1000,
           "completion_tokens": 200, "usage": 0.5, "requests": 3},
          {"date": "2026-10-02", "model": "anthropic/claude-sonnet-4.5", "prompt_tokens": 500,
           "completion_tokens": 100, "usage": 0.25, "requests": 1},
          {"date": "2026-10-02", "model": "openai/gpt-5", "prompt_tokens": 300,
           "completion_tokens": 100, "usage": 0.1, "requests": 1}
        ]}
        """.utf8)
        let rows = try #require(OpenRouterActivityParser.parse(data))
        #expect(rows.map(\.model) == ["anthropic/claude-sonnet-4.5", "openai/gpt-5"])
        #expect(rows[0].totalTokens == 1_800)
        #expect(abs((rows[0].costCents ?? 0) - 75) < 0.0001)
        #expect(OpenRouterActivityParser.parse(Data("{}".utf8)) == nil)
    }

    @Test("A rejected or stalled OpenRouter activity request yields no usage")
    func openRouterActivityFailures() async {
        let rejected = await OpenRouterUsageService.fetchModelUsage(apiKey: "fixture") { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        #expect(rejected == .unavailable)

        let stalled = await OpenRouterUsageService.fetchModelUsage(apiKey: "fixture", timeout: 0.03) { _ in
            try await Task.sleep(for: .seconds(60))
            throw URLError(.unknown)
        }
        #expect(stalled == .unavailable)

        let served = await OpenRouterUsageService.fetchModelUsage(apiKey: "fixture") { request in
            let body = #"{"data":[{"model":"openai/gpt-5","prompt_tokens":10,"completion_tokens":5,"usage":0.01}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(served.usage?.first?.model == "openai/gpt-5")
        #expect(served.period == .days(30))
    }

    @Test("new-api hourly quota data sums per model and converts quota to USD")
    func parsesNewAPIQuotaData() throws {
        let data = Data("""
        {"success": true, "message": "", "data": [
          {"model_name": "claude-sonnet-4-5", "token_used": 1200, "quota": 250000, "count": 3, "created_at": 1783990800},
          {"model_name": "claude-sonnet-4-5", "token_used": 800, "quota": 250000, "count": 1, "created_at": 1783994400},
          {"model_name": "gpt-5", "token_used": 500, "quota": 50000, "count": 2, "created_at": 1783994400}
        ]}
        """.utf8)
        let rows = try #require(ThirdPartyModelUsageParser.parseQuotaData(data, quotaPerUnit: 500_000))
        #expect(rows.map(\.model) == ["claude-sonnet-4-5", "gpt-5"])
        #expect(rows[0].totalTokens == 2_000)
        #expect(rows[0].costCents == 100)
        #expect(ThirdPartyModelUsageParser.parseQuotaData(
            Data(#"{"success": false, "message": "denied"}"#.utf8),
            quotaPerUnit: 500_000
        ) == nil)
    }

    @Test("new-api key logs count only consumption requests")
    func parsesNewAPITokenLogs() throws {
        let data = Data("""
        {"success": true, "message": "", "data": [
          {"type": 2, "model_name": "deepseek-v3.1", "prompt_tokens": 100, "completion_tokens": 40, "quota": 5000},
          {"type": 2, "model_name": "kimi-k2", "prompt_tokens": 50, "completion_tokens": 10, "quota": 1000},
          {"type": 1, "model_name": "", "prompt_tokens": 0, "completion_tokens": 0, "quota": 500000},
          {"type": 2, "model_name": "deepseek-v3.1", "prompt_tokens": 10, "completion_tokens": 0, "quota": 500}
        ]}
        """.utf8)
        let logs = try #require(ThirdPartyModelUsageParser.parseTokenLogs(data, quotaPerUnit: 500_000))
        #expect(logs.requests == 3)
        #expect(logs.usage.map(\.model) == ["deepseek-v3.1", "kimi-k2"])
        #expect(logs.usage[0].totalTokens == 150)
    }

    @Test("Model usage is fetched once per interval and keeps the last good value")
    func throttle() async {
        let throttle = ModelUsageThrottle()
        let key = ModelUsageThrottle.key("fixture", "secret")
        let good = ModelUsageThrottle.Value(
            usage: [ProviderModelUsage(model: "gpt-5", inputTokens: 1, outputTokens: 0, cacheWriteTokens: 0, cacheReadTokens: 0, costCents: nil)],
            period: .days(30)
        )
        let counter = FetchCounter()

        let first = await throttle.value(for: key, now: now) { await counter.hit(); return good }
        let cached = await throttle.value(for: key, now: now.addingTimeInterval(60)) { await counter.hit(); return .unavailable }
        #expect(first == good)
        #expect(cached == good)
        #expect(await counter.count == 1)

        let afterFailure = await throttle.value(for: key, now: now.addingTimeInterval(ModelUsageThrottle.interval + 1)) {
            await counter.hit(); return .unavailable
        }
        #expect(afterFailure == good)
        #expect(await counter.count == 2)
        #expect(!key.contains("secret"))
    }

    @Test("The list title names the period the usage covers")
    func listTitles() {
        #expect(ProviderModelUsageRow.title(for: nil) == L10n.text("quota.models_this_cycle"))
        #expect(ProviderModelUsageRow.title(for: .days(30)) == L10n.format("quota.models_recent_days", 30))
        #expect(ProviderModelUsageRow.title(for: .recentRequests(12)) == L10n.format("quota.models_recent_requests", 12))
    }

    @Test("The usage period survives the cache round-trip and old caches still decode")
    func cacheRoundTrip() throws {
        var quota = ProviderQuota(
            provider: .thirdParty,
            primary: QuotaWindow(usedPercent: 20, windowMinutes: 0, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: now
        )
        quota.modelUsagePeriod = .recentRequests(7)
        let decoded = try JSONDecoder().decode(ProviderQuota.self, from: JSONEncoder().encode(quota))
        #expect(decoded.modelUsagePeriod == .recentRequests(7))

        var legacy = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(quota)) as? [String: Any]
        )
        legacy.removeValue(forKey: "modelUsagePeriod")
        let old = try JSONDecoder().decode(ProviderQuota.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.modelUsagePeriod == nil)
    }
}

private actor FetchCounter {
    private(set) var count = 0
    func hit() { count += 1 }
}
