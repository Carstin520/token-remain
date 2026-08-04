import Foundation
import Testing
@testable import UsageDock

@Suite("Grok usage parser")
struct GrokUsageParserTests {
    @Test("Parses the weekly shared pool from proto-JSON")
    func parsesWeeklyPool() throws {
        let payload = """
        {
          "config": {
            "creditUsagePercent": 37.5,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-07-17T04:01:09.238389+00:00",
              "end": "2026-07-24T04:01:09.238389+00:00"
            },
            "onDemandCap": {"val": 2500}
          }
        }
        """
        let quota = try GrokUsageParser.parse(Data(payload.utf8), planName: "SuperGrok")

        #expect(quota.provider == .grok)
        #expect(quota.primary.usedPercent == 37.5)
        #expect(quota.primary.windowMinutes == 7 * 24 * 60)
        #expect(quota.primary.resetsAt != nil)
        #expect(quota.secondary == nil)
        #expect(quota.planName == "SuperGrok")
    }

    @Test("An absent usage percent is a genuine zero, not an error")
    func absentPercentIsZero() throws {
        let payload = """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-07-17T04:00:00Z",
              "end": "2026-07-24T04:00:00Z"
            }
          }
        }
        """
        let quota = try GrokUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 0)
    }

    @Test("A response without a usable period is rejected")
    func missingPeriodThrows() {
        #expect(throws: (any Error).self) {
            try GrokUsageParser.parse(Data(#"{"config": {"creditUsagePercent": 5}}"#.utf8))
        }
    }

    @Test("Plan name comes from settings' subscription_tier_display")
    func planFromSettings() {
        let payload = #"{"subscription_tier_display": "SuperGrok Heavy"}"#
        #expect(GrokUsageParser.planName(Data(payload.utf8)) == "SuperGrok Heavy")
        #expect(GrokUsageParser.planName(Data(#"{}"#.utf8)) == nil)
    }
}

@Suite("Grok auth reader")
struct GrokAuthReaderTests {
    @Test("Picks the first entry with a non-empty key, stable by name")
    func picksFirstEntry() {
        let payload = """
        {
          "b-entry": {"key": "token-b", "refresh_token": "rt"},
          "a-entry": {"key": "token-a", "refresh_token": "rt"}
        }
        """
        let auth = GrokAuthReader.parse(Data(payload.utf8))
        #expect(auth?.token == "token-a")
    }

    @Test("Entries without keys are skipped; empty file yields nil")
    func skipsKeylessEntries() {
        let payload = #"{"one": {"refresh_token": "rt"}, "two": {"key": "  "}}"#
        #expect(GrokAuthReader.parse(Data(payload.utf8)) == nil)
        #expect(GrokAuthReader.parse(Data("{}".utf8)) == nil)
    }

    @Test("expires_at ISO string is honored when the key is not a JWT")
    func entryExpiryParsed() {
        let payload = #"{"main": {"key": "opaque-token", "expires_at": "2026-07-01T00:00:00Z"}}"#
        let auth = GrokAuthReader.parse(Data(payload.utf8))
        #expect(auth?.expiry == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    }
}

@Suite("Z.ai usage parser")
struct ZAIUsageParserTests {
    @Test("Splits TOKENS_LIMIT entries into session and weekly windows")
    func parsesSessionAndWeekly() throws {
        let payload = """
        {
          "data": {
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12, "nextResetTime": 1784005200000},
              {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 44, "nextResetTime": 1784500000000},
              {"type": "TIME_LIMIT", "unit": 5, "number": 1, "currentValue": 3, "usage": 100}
            ]
          }
        }
        """
        let quota = try ZAIUsageParser.parse(Data(payload.utf8), planName: "GLM Coding Max")

        #expect(quota.provider == .zai)
        #expect(quota.primary.usedPercent == 12)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_784_005_200))
        #expect(quota.secondary?.usedPercent == 44)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.scopedWindows?.first?.scopeID == "zai_mcp_monthly")
        #expect(quota.scopedWindows?.first?.window.usedPercent == 3)
        #expect(quota.planName == "GLM Coding Max")
    }

    @Test("A weekly-only payload still yields a primary window")
    func weeklyOnly() throws {
        let payload = """
        {"data": {"limits": [{"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 80}]}}
        """
        let quota = try ZAIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.secondary == nil)
    }

    @Test("Two longer token limits remain visible in ascending duration order")
    func twoLongWindows() throws {
        let payload = #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":1,"number":1,"percentage":20},{"type":"TOKENS_LIMIT","unit":1,"number":30,"percentage":70}]}}"#
        let quota = try ZAIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.windowMinutes == 1_440)
        #expect(quota.secondary?.windowMinutes == 43_200)
    }

    @Test("The no-coding-plan business response is detected")
    func detectsNoCodingPlan() {
        let payload = #"{"success": false, "code": 500, "msg": "User does not have a coding plan"}"#
        #expect(ZAIUsageParser.isNoCodingPlan(Data(payload.utf8)))
        #expect(!ZAIUsageParser.isNoCodingPlan(Data(#"{"success": true}"#.utf8)))
    }

    @Test("An empty or unrecognized limits payload is rejected")
    func emptyLimitsThrows() {
        #expect(throws: (any Error).self) {
            try ZAIUsageParser.parse(Data(#"{"data": {"limits": []}}"#.utf8))
        }
    }

    @Test("Subscription list yields the product name")
    func planName() {
        let payload = #"{"data": [{"productName": "GLM Coding Pro", "next_renew_time": "2026-09-01T00:00:00Z"}]}"#
        #expect(ZAIUsageParser.planName(Data(payload.utf8)) == "GLM Coding Pro")
        #expect(
            ZAIUsageParser.subscriptionResetAt(Data(payload.utf8))
                == ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")
        )
    }

    @Test("limit_type and subscription renewal populate the MCP window")
    func mcpFallbackReset() throws {
        let payload = Data(#"{"data":{"limits":[{"limit_type":"TIME_LIMIT","percentage":30}]}}"#.utf8)
        let reset = try #require(ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        let quota = try ZAIUsageParser.parse(payload, subscriptionResetAt: reset)
        #expect(quota.scopedWindows?.first?.window.resetsAt == reset)
    }
}

@Suite("Z.ai key store")
struct ZAIKeyStoreTests {
    @Test("Config text accepts JSON field variants and bare keys")
    func configTextParsing() {
        #expect(ZAIKeyStore.key(fromConfigText: #"{"apiKey": "k1"}"#) == "k1")
        #expect(ZAIKeyStore.key(fromConfigText: #"{"api_key": "k2"}"#) == "k2")
        #expect(ZAIKeyStore.key(fromConfigText: #"{"key": "k3"}"#) == "k3")
        #expect(ZAIKeyStore.key(fromConfigText: "bare-key\n") == "bare-key")
        #expect(ZAIKeyStore.key(fromConfigText: #""quoted-key""#) == "quoted-key")
        #expect(ZAIKeyStore.key(fromConfigText: #"{"other": 1}"#) == nil)
        #expect(ZAIKeyStore.key(fromConfigText: "  ") == nil)
    }

    @Test("Environment variable takes precedence over everything")
    func envPrecedence() {
        var store = ZAIKeyStore()
        store.environment = ["ZAI_API_KEY": " env-key "]
        store.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-zai-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(store.load() == "env-key")
    }
}

@Suite("Z.ai region")
struct ZAIRegionStoreTests {
    @Test("China aliases select the bigmodel endpoint")
    func aliases() {
        #expect(ZAIAPIRegion.parse("bigmodel-cn") == .china)
        #expect(ZAIAPIRegion.parse("https://open.bigmodel.cn") == .china)
        #expect(ZAIAPIRegion.parse("global") == .global)
        #expect(ZAIAPIRegion.china.baseURL.host == "open.bigmodel.cn")
    }

    @Test("Saved region persists when no environment override exists")
    func persistence() throws {
        let suite = "ZAIRegionStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = ZAIRegionStore(defaults: defaults)
        store.environment = [:]
        store.save(.china)
        #expect(store.load() == .china)
        store.environment = ["ZAI_API_REGION": "global"]
        #expect(store.load() == .global)
    }
}
