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
        // onDemandCap 只有上限没有已花费字段,不臆造 ExtraUsage(spentUSD: 0)。
        #expect(quota.extraUsage == nil)
    }

    @Test("On-demand cap parses its shape but never fabricates a zero spend")
    func onDemandCapWithoutSpend() throws {
        // 取证结论(对照 OpenUsage 同接口解码器):billing?format=credits
        // 只带 config.onDemandCap {val}(积分单位),响应里没有任何
        // on-demand "已花费"字段;拿到真实样本前 ExtraUsage 不落地。
        let payload = """
        {
          "config": {
            "creditUsagePercent": 100,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-07-17T04:00:00Z",
              "end": "2026-07-24T04:00:00Z"
            },
            "onDemandCap": {"val": 2500}
          }
        }
        """
        #expect(GrokUsageParser.onDemandCapCredits(Data(payload.utf8)) == 2500)
        // 停用时字段整个缺席(proto-JSON 丢零值)→ nil。
        #expect(GrokUsageParser.onDemandCapCredits(Data(#"{"config":{}}"#.utf8)) == nil)
        // 主池打满、cap 存在也不推断已花费:0 会把"未按量消费"当成事实端出去。
        let quota = try GrokUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 100)
        #expect(quota.extraUsage == nil)
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
        #expect(quota.primary.poolName == nil)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_784_005_200))
        #expect(quota.secondary?.usedPercent == 44)
        #expect(quota.secondary?.windowMinutes == 10_080)
        let mcp = try #require(quota.scopedWindows?.first)
        // TIME_LIMIT 的时长来自条目自身 (unit=5, number=1) = 1 分钟,
        // 不再硬编码 30 天;无 name 时保留 "MCP" 兜底名。
        #expect(mcp.scopeID == "zai_mcp_1m")
        #expect(mcp.displayName == "MCP")
        #expect(mcp.window.windowMinutes == 1)
        #expect(mcp.window.usedPercent == 3)
        #expect(mcp.observedAt != nil)
        #expect(quota.planName == "GLM Coding Max")
    }

    @Test("TIME_LIMIT entries keep their own duration, name, and scope identity")
    func timeLimitRealDurations() throws {
        let payload = """
        {
          "data": {
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10},
              {"type": "TIME_LIMIT", "unit": 1, "number": 30, "name": "MCP Calls", "percentage": 12},
              {"type": "TIME_LIMIT", "unit": 3, "number": 1, "name": "Web Search", "percentage": 5}
            ]
          }
        }
        """
        let quota = try ZAIUsageParser.parse(Data(payload.utf8))
        let scoped = try #require(quota.scopedWindows)
        // 两条 TIME_LIMIT 不再共用一个 scopeID 塌缩成一条。
        #expect(scoped.map(\.scopeID) == ["zai_mcp_calls", "zai_web_search"])
        #expect(scoped.map(\.displayName) == ["MCP Calls", "Web Search"])
        #expect(scoped.map(\.window.windowMinutes) == [43_200, 60])
        #expect(scoped.map(\.window.usedPercent) == [12, 5])
    }

    @Test("Same-duration token pools survive: busiest primary, sibling scoped")
    func sameDurationTokenPools() throws {
        let payload = """
        {
          "data": {
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10, "name": "GLM-5"},
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 60, "name": "GLM-5-Air"},
              {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 30}
            ]
          }
        }
        """
        let quota = try ZAIUsageParser.parse(Data(payload.utf8))
        // 同时长双池不再去重丢弃:最忙的池做带名主窗口,兄弟池 scoped;
        // 第一对不同时长的窗仍占 primary/secondary。
        #expect(quota.primary.usedPercent == 60)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.poolName == "GLM-5-Air")
        #expect(quota.secondary?.usedPercent == 30)
        #expect(quota.secondary?.windowMinutes == 10_080)
        let sibling = try #require(quota.scopedWindows?.first)
        #expect(quota.scopedWindows?.count == 1)
        #expect(sibling.scopeID == "zai_glm_5")
        #expect(sibling.displayName == "GLM-5")
        #expect(sibling.window.usedPercent == 10)
        #expect(sibling.window.windowMinutes == 300)
        #expect(sibling.observedAt != nil)
    }

    @Test("A same-duration sibling in the longest tier keeps the secondary named")
    func sameDurationSecondaryKeepsName() throws {
        let payload = """
        {
          "data": {
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10},
              {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 70, "name": "Weekly Pro"},
              {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 20, "name": "Weekly Lite"}
            ]
          }
        }
        """
        let quota = try ZAIUsageParser.parse(Data(payload.utf8))
        // 最长档有同时长兄弟:兄弟保名进 scoped,更忙的 secondary 不能
        // 反而匿名——它同样是命名池,带 poolName。
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.poolName == nil)
        #expect(quota.secondary?.usedPercent == 70)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.secondary?.poolName == "Weekly Pro")
        let sibling = try #require(quota.scopedWindows?.first)
        #expect(quota.scopedWindows?.count == 1)
        #expect(sibling.displayName == "Weekly Lite")
        #expect(sibling.window.usedPercent == 20)
    }

    @Test("Entry names skip type tokens per field and fall through to display candidates")
    func entryNameFallsThroughTypeTokens() throws {
        // name 被上游当类型字段用("TOKENS_LIMIT")时不能整体放弃,
        // 要继续扫 display_name/displayName/show_name 等候选。
        let payload = """
        {
          "data": {
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 60,
               "name": "TOKENS_LIMIT", "display_name": "GLM-5 Pool"},
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10,
               "name": "TIME_LIMIT", "show_name": "Air Pool"}
            ]
          }
        }
        """
        let quota = try ZAIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 60)
        #expect(quota.primary.poolName == "GLM-5 Pool")
        let sibling = try #require(quota.scopedWindows?.first)
        #expect(sibling.displayName == "Air Pool")
        #expect(sibling.scopeID == "zai_air_pool")
    }

    @Test("A third distinct duration lands scoped with a duration-word name")
    func threeDistinctDurations() throws {
        let payload = #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12},{"type":"TOKENS_LIMIT","unit":1,"number":1,"percentage":50},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":44}]}}"#
        let quota = try ZAIUsageParser.parse(Data(payload.utf8))
        // 中间档(日窗)不再静默丢弃:5h 主、7d 副维持既有形态,1d 进 scoped。
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.secondary?.usedPercent == 44)
        let middle = try #require(quota.scopedWindows?.first)
        #expect(middle.scopeID == "zai_tokens_1440m")
        #expect(middle.window.windowMinutes == 1_440)
        #expect(middle.window.usedPercent == 50)
        #expect(!middle.displayName.isEmpty)
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
        // 没有 TOKENS_LIMIT 时唯一的 TIME_LIMIT 提升为主窗口并移出 scoped,
        // 同一池不再渲染两次;(unit, number) 缺失才退月窗兜底。
        #expect(quota.primary.usedPercent == 30)
        #expect(quota.primary.resetsAt == reset)
        #expect(quota.primary.windowMinutes == 43_200)
        #expect(quota.primary.poolName == "MCP")
        #expect(quota.scopedWindows == nil)
    }

    @Test("A TIME_LIMIT-only payload promotes the first entry without duplicating it")
    func timeLimitOnlyPromotion() throws {
        let payload = Data(
            #"{"data":{"limits":[{"type":"TIME_LIMIT","unit":1,"number":30,"name":"MCP Calls","percentage":12},{"type":"TIME_LIMIT","unit":3,"number":1,"name":"Web Search","percentage":5}]}}"#
                .utf8
        )
        let quota = try ZAIUsageParser.parse(payload)
        // 首条提升做主窗口并带池名;它必须从 scoped 集合移除,
        // 桌面和手机才不会看到同一池两次。
        #expect(quota.primary.usedPercent == 12)
        #expect(quota.primary.windowMinutes == 43_200)
        #expect(quota.primary.poolName == "MCP Calls")
        #expect(quota.secondary == nil)
        let scoped = try #require(quota.scopedWindows)
        #expect(scoped.map(\.displayName) == ["Web Search"])
        #expect(scoped.map(\.window.usedPercent) == [5])
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
