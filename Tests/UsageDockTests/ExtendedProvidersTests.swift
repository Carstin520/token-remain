import Foundation
import Testing
@testable import UsageDock

@Suite("Extended providers (token-monitor compat)")
struct ExtendedProvidersTests {
    @Test("DeepSeek balance keeps its availability meter and exposes a monetary value")
    func deepseek() throws {
        let payload = """
        {"is_available": true, "balance_infos": [
            {"currency": "CNY", "total_balance": "110.55"},
            {"currency": "USD", "total_balance": "0.00"}
        ]}
        """
        let quota = try DeepSeekUsageService.parse(Data(payload.utf8))
        #expect(quota.provider == .deepseek)
        #expect(quota.primary.usedPercent == 0)
        #expect(quota.primary.windowMinutes == 0)
        #expect(quota.planName == "余额 ¥110.55")
        // 未充值的 0.00 占位币种不应生成 scoped 行。
        #expect(quota.uniqueScopedWindows.isEmpty)
        #expect(quota.remainingBalance == QuotaBalance(amount: 110.55, currencyCode: "CNY"))
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 110.55, currencyCode: "CNY"))
        #expect(quota.remainingBalance?.displayText == "¥110.55")
        #expect(
            QuotaWindowRow.remainingValueText(
                remainingPercent: 100,
                remainingBalance: quota.remainingBalance
            ) == "¥110.55"
        )

        let exhausted = try DeepSeekUsageService.parse(
            Data(#"{"is_available": false, "balance_infos": []}"#.utf8)
        )
        #expect(exhausted.primary.usedPercent == 100)
        #expect(exhausted.remainingBalance?.displayText == "0.00")
    }

    @Test("Currency display covers CNY, USD, JPY, and unknown codes")
    func currencyDisplay() {
        #expect(QuotaBalance(amount: 12.3, currencyCode: "CNY").displayText == "¥12.30")
        #expect(QuotaBalance(amount: 12.3, currencyCode: "usd").displayText == "$12.30")
        #expect(QuotaBalance(amount: 12.3, currencyCode: " JPY ").displayText == "¥12.30")
        #expect(QuotaBalance(amount: 12.3, currencyCode: "USDT").displayText == "USDT 12.30")
        #expect(QuotaBalance(amount: .infinity, currencyCode: "USD").displayText == "$0.00")
    }

    @Test("DeepSeek keeps the first funded currency as the main row and scopes the other one")
    func deepseekDualCurrency() throws {
        let payload = """
        {"is_available": true, "balance_infos": [
            {"currency": "USD", "total_balance": "4.25"},
            {"currency": "CNY", "total_balance": "30.00"}
        ]}
        """
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let quota = try DeepSeekUsageService.parse(Data(payload.utf8), now: now)
        // 主行维持首个有余额币种的既有口径。
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 4.25, currencyCode: "USD"))
        #expect(quota.primary.remainingBalance?.displayText == "$4.25")
        #expect(quota.primary.usedPercent == 0)
        // 另一充值币种不再被吞:独立一条 scoped 余额行。
        let scoped = quota.uniqueScopedWindows
        #expect(scoped.map(\.scopeID) == ["deepseek_cny"])
        let cny = try #require(scoped.first)
        #expect(cny.displayName == "CNY")
        #expect(cny.window.windowMinutes == 0)
        #expect(cny.window.usedPercent == 0)
        #expect(cny.window.remainingBalance == QuotaBalance(amount: 30, currencyCode: "CNY"))
        #expect(cny.observedAt == now)
    }

    @Test("Kimi limits entries split into session and weekly windows")
    func kimi() throws {
        let payload = """
        {"limits": [
            {"detail": {"used": 30, "limit": 100, "resetTime": 1784005200000},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}},
            {"detail": {"percent": 55},
             "window": {"duration": 1, "timeUnit": "TIME_UNIT_WEEK"}}
        ]}
        """
        let quota = try KimiUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 30)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_784_005_200))
        #expect(quota.secondary?.usedPercent == 55)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.uniqueScopedWindows.isEmpty)
    }

    @Test("Kimi keeps every window: shortest primary, longest secondary, middle tiers scoped")
    func kimiThreeTierWindows() throws {
        // 周窗排最前:结果不得依赖 limits[] 的到达顺序。
        let payload = """
        {"limits": [
            {"detail": {"percent": 55},
             "window": {"duration": 1, "timeUnit": "TIME_UNIT_WEEK"}},
            {"name": "Daily quota", "detail": {"used": 90, "limit": 100},
             "window": {"duration": 1, "timeUnit": "TIME_UNIT_DAY"}},
            {"detail": {"used": 30, "limit": 100},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}}
        ]}
        """
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let quota = try KimiUsageService.parse(Data(payload.utf8), now: now)
        #expect(quota.primary.usedPercent == 30)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.usedPercent == 55)
        #expect(quota.secondary?.windowMinutes == 10_080)
        // 中间档(日窗)不再被丢弃,带上游名字进 scoped。
        let scoped = quota.uniqueScopedWindows
        #expect(scoped.map(\.scopeID) == ["kimi_daily_quota"])
        let daily = try #require(scoped.first)
        #expect(daily.displayName == "Daily quota")
        #expect(daily.window.usedPercent == 90)
        #expect(daily.window.windowMinutes == 1_440)
        #expect(daily.observedAt == now)
    }

    @Test("Kimi same-duration sibling pools promote the busiest one, named, to primary")
    func kimiSameDurationSiblings() throws {
        let payload = """
        {"limits": [
            {"detail": {"used": 10, "limit": 100},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}},
            {"detail": {"used": 70, "limit": 100},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}},
            {"detail": {"percent": 40},
             "window": {"duration": 1, "timeUnit": "TIME_UNIT_WEEK"}}
        ]}
        """
        let quota = try KimiUsageService.parse(Data(payload.utf8))
        // 同时长档内选最忙的做 primary,不再按响应顺序先到先得;
        // 有兄弟池时它是命名池,带 poolName(名字来源与 scoped 相同)。
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.usedPercent == 70)
        #expect(quota.primary.poolName == "Session")
        #expect(quota.secondary?.windowMinutes == 10_080)
        // 周窗档没有兄弟,secondary 不带池名。
        #expect(quota.secondary?.poolName == nil)
        // 同时长兄弟窗不占 primary/secondary(手机同步拒绝同时长双窗),入 scoped。
        let scoped = quota.uniqueScopedWindows
        #expect(scoped.map(\.scopeID) == ["kimi_session"])
        #expect(scoped.first?.displayName == "Session")
        #expect(scoped.first?.window.usedPercent == 10)
        #expect(scoped.first?.window.windowMinutes == 300)
    }

    @Test("Kimi picks the busiest sibling in both selected tiers, response order breaking ties")
    func kimiBusiestSiblingPerTier() throws {
        // 两个档各有同时长兄弟:被选中的窗口都必须是档内最忙的且带池名;
        // 平手时响应顺序裁决(先到先得)。
        let payload = """
        {"limits": [
            {"name": "Idle pool", "detail": {"used": 10, "limit": 100},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}},
            {"name": "Busy pool", "detail": {"used": 70, "limit": 100},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}},
            {"name": "Weekly A", "detail": {"percent": 40},
             "window": {"duration": 1, "timeUnit": "TIME_UNIT_WEEK"}},
            {"name": "Weekly B", "detail": {"percent": 40},
             "window": {"duration": 1, "timeUnit": "TIME_UNIT_WEEK"}}
        ]}
        """
        let quota = try KimiUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 70)
        #expect(quota.primary.poolName == "Busy pool")
        #expect(quota.secondary?.usedPercent == 40)
        #expect(quota.secondary?.poolName == "Weekly A")
        let scoped = quota.uniqueScopedWindows
        #expect(scoped.map(\.displayName) == ["Idle pool", "Weekly B"])
        #expect(scoped.map(\.window.usedPercent) == [10, 40])
    }

    @Test("Kimi with only same-duration windows keeps the busiest primary and scopes the rest")
    func kimiAllSameDuration() throws {
        let payload = """
        {"limits": [
            {"detail": {"used": 20, "limit": 100},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}},
            {"detail": {"used": 80, "limit": 100},
             "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}}
        ]}
        """
        let quota = try KimiUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 80)
        #expect(quota.primary.poolName == "Session")
        #expect(quota.secondary == nil)
        #expect(quota.uniqueScopedWindows.count == 1)
        #expect(quota.uniqueScopedWindows.first?.window.usedPercent == 20)
    }

    @Test("MiniMax general lane flips remaining percents into windows")
    func minimax() throws {
        let payload = """
        {"data": {"model_remains": [
            {"model_name": "video", "current_interval_remaining_percent": "0"},
            {"model_name": "general",
             "current_interval_remaining_percent": "72.5", "end_time": 1784005200000,
             "current_weekly_remaining_percent": "40", "weekly_end_time": 1784500000000}
        ]}}
        """
        let quota = try MiniMaxUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 27.5)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.usedPercent == 60)
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["minimax_video_session"])
        #expect(quota.uniqueScopedWindows.first?.window.usedPercent == 100)
    }

    @Test("MiMo month_total_token is found anywhere in the payload")
    func mimo() throws {
        let payload = """
        {"data": {"items": [
            {"name": "day_token", "used": 1, "limit": 10},
            {"name": "month_total_token", "used": 250, "limit": 1000}
        ]}}
        """
        let quota = try MiMoUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.windowMinutes == 43_200)
        // day_token 不再被吞:独立一条 scoped "Daily" 行。
        let daily = try #require(quota.uniqueScopedWindows.first)
        #expect(quota.uniqueScopedWindows.count == 1)
        #expect(daily.scopeID == "mimo_daily")
        #expect(daily.displayName == "Daily")
        #expect(daily.window.usedPercent == 10)
        #expect(daily.window.windowMinutes == 1_440)
    }

    @Test("MiMo keeps the plan primary, scopes day_token, and moves the wallet to accountBalance")
    func mimoManagedAccount() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let balance = Data(#"{"data":{"balance":"12.5","currency":"CNY"}}"#.utf8)
        let detail = Data(#"{"data":{"planName":"Coding Pro","status":"active","currentPeriodEnd":"2030-08-31T00:00:00Z"}}"#.utf8)
        let usage = Data(#"""
        {"data":{"monthUsage":{"items":[
            {"name": "day_token", "used": 95, "limit": 100},
            {"name": "month_total_token", "used": 850, "limit": 1000, "percent": 0.85}
        ]}}}
        """#.utf8)
        let quota = try MiMoUsageService.parse(
            balanceData: balance,
            detailData: detail,
            usageData: usage,
            now: now
        )
        #expect(quota.primary.usedPercent == 85)
        #expect(quota.primary.windowMinutes == 43_200)
        #expect(quota.planName == "Coding Pro")
        // 钱包不再占 secondary 槽,改挂 accountBalance。
        #expect(quota.secondary == nil)
        #expect(quota.accountBalance == QuotaBalance(amount: 12.5, currencyCode: "CNY"))
        // 当天几乎耗尽必须可见:day_token 成 scoped "Daily" 行。
        let daily = try #require(quota.uniqueScopedWindows.first)
        #expect(quota.uniqueScopedWindows.count == 1)
        #expect(daily.scopeID == "mimo_daily")
        #expect(daily.displayName == "Daily")
        #expect(daily.window.usedPercent == 95)
        #expect(daily.window.windowMinutes == 1_440)
        #expect(daily.observedAt == now)
        // 上游没给重置字段时按当日边界推算:落在未来 24 小时内。
        let resetsAt = try #require(daily.window.resetsAt)
        #expect(resetsAt > now)
        #expect(resetsAt.timeIntervalSince(now) <= 86_400)
    }

    @Test("MiMo empty wallet no longer hijacks the summary as a zero-minute secondary")
    func mimoEmptyWalletWithActivePlan() throws {
        let balance = Data(#"{"data":{"balance":0,"currency":"CNY"}}"#.utf8)
        let detail = Data(#"{"data":{"planName":"Coding Pro","status":"active","currentPeriodEnd":"2030-08-31T00:00:00Z"}}"#.utf8)
        let usage = Data(#"{"data":{"monthUsage":{"items":[{"name":"month_total_token","used":250,"limit":1000}]}}}"#.utf8)
        let quota = try MiMoUsageService.parse(
            balanceData: balance,
            detailData: detail,
            usageData: usage,
            now: Date(timeIntervalSince1970: 1_784_000_000)
        )
        // 旧行为:空钱包成 0 分钟 100% 窗口,lowestRemaining 策略下劫持菜单栏。
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.windowMinutes == 43_200)
        #expect(quota.secondary == nil)
        #expect(quota.accountBalance == QuotaBalance(amount: 0, currencyCode: "CNY"))
    }

    @Test("MiMo explicit inactive state and unrelated usage items do not create a plan")
    func mimoInactivePlan() throws {
        let balance = Data(#"{"data":{"balance":12,"currency":"CNY"}}"#.utf8)
        let detail = Data(#"{"data":{"planName":"Coding Pro","active":false,"currentPeriodEnd":"2030-08-31T00:00:00Z"}}"#.utf8)
        let usage = Data(#"{"data":{"monthUsage":{"items":[{"name":"day_token","used":1,"limit":10}]}}}"#.utf8)
        let quota = try MiMoUsageService.parse(
            balanceData: balance,
            detailData: detail,
            usageData: usage,
            now: Date(timeIntervalSince1970: 1_784_000_000)
        )
        #expect(quota.primary.windowMinutes == 0)
        #expect(quota.secondary == nil)
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 12, currencyCode: "CNY"))
        #expect(quota.accountBalance == QuotaBalance(amount: 12, currencyCode: "CNY"))
        // 套餐未激活时 day_token 不成行。
        #expect(quota.uniqueScopedWindows.isEmpty)
    }

    @Test("MiMo accepts fractional period ends without an explicit timezone")
    func mimoFractionalLocalPeriodEnd() throws {
        let balance = Data(#"{"data":{"balance":12,"currency":"CNY"}}"#.utf8)
        let detail = Data(#"{"data":{"planName":"Coding Pro","currentPeriodEnd":"2030-08-31 00:00:00.123"}}"#.utf8)
        let usage = Data(#"{"data":{"monthUsage":{"items":[{"name":"month_total_token","used":40,"limit":100,"percent":0.4}]}}}"#.utf8)
        let quota = try MiMoUsageService.parse(
            balanceData: balance,
            detailData: detail,
            usageData: usage,
            now: Date(timeIntervalSince1970: 1_784_000_000)
        )
        #expect(quota.primary.usedPercent == 40)
        #expect(quota.planName == "Coding Pro")
    }

    @Test("MiMo percent is always a ratio when used and limit are absent")
    func mimoRatioScale() throws {
        let payload = Data(#"{"monthUsage":{"items":[{"name":"month_total_token","percent":1.005}]}}"#.utf8)
        let quota = try MiMoUsageService.parse(payload)
        #expect(quota.primary.usedPercent == 100)
    }

    @Test("MiMo cookie keeps only the managed-session fields and requires identity")
    func mimoCookieNormalization() {
        let normalized = MiMoUsageService.normalizedCookie(
            "Cookie: userId=u1; noise=drop; api-platform_serviceToken=t1; api-platform_ph=p1"
        )
        #expect(normalized == "api-platform_ph=p1; api-platform_serviceToken=t1; userId=u1")
        #expect(MiMoUsageService.normalizedCookie("api-platform_serviceToken=t1") == nil)
    }

    @Test("Qoder keeps personal and shared credit pools separate, busier pool first")
    func qoder() throws {
        // 个人池耗尽 + 共享池几乎未动:求和会稀释成 ~9%,拆池后瓶颈必须置顶。
        let payload = """
        {"totalQuota": {"quotaSummary": {"usedValue": 100, "limitValue": 100}},
         "sharedQuota": {"quotaSummary": {"usedValue": 0, "limitValue": 1000}}}
        """
        let quota = try QoderUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 100)
        #expect(quota.primary.poolName == "Personal")
        #expect(quota.secondary == nil)
        let shared = try #require(quota.uniqueScopedWindows.first)
        #expect(shared.scopeID == "qoder_shared")
        #expect(shared.displayName == "Shared")
        #expect(shared.window.usedPercent == 0)
        #expect(quota.uniqueScopedWindows.count == 1)
    }

    @Test("Kiro CLI report parses bar percent, credits fallback, and reset date")
    func kiro() throws {
        let bar = "Plan: Free\n█████░░░░░ 42%\ncredits resets on 2026-08-01"
        let quota = try KiroUsageService.parse(bar)
        #expect(quota.primary.usedPercent == 42)
        #expect(quota.primary.resetsAt != nil)

        let credits = "Usage (12.5 of 50 covered)"
        #expect(try KiroUsageService.parse(credits).primary.usedPercent == 25)
    }

    @Test("Volcengine result percent is found in nested Result payloads")
    func volcengine() throws {
        let payload = #"{"Result": {"user_limit": {"Percent": 66}}}"#
        let quota = try VolcengineUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 66)
    }

    @Test("Volcengine prefers the explicit user_limit path over other Percent fields")
    func volcengineExplicitPathWins() throws {
        // "alpha" 排在 "user_limit" 前;若按排序递归会先命中 12——显式路径必须赢。
        let payload = #"{"Result": {"alpha": {"Percent": 12}, "user_limit": {"Percent": 66}}}"#
        let quota = try VolcengineUsageService.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 66)
    }

    @Test("Volcengine falls back to a deterministic key-sorted Percent search")
    func volcengineDeterministicFallback() throws {
        // 无 user_limit 时递归按 key 排序:多次解析必须始终取同一个池,
        // 不再随 Dictionary 遍历顺序跨启动漂移。
        let payload = #"{"Result": {"zebra_pool": {"Percent": 90}, "alpha_pool": {"Percent": 10}}}"#
        for _ in 0..<8 {
            let quota = try VolcengineUsageService.parse(Data(payload.utf8))
            #expect(quota.primary.usedPercent == 10)
        }
    }

    @Test("Ollama settings HTML yields session and weekly windows")
    func ollama() throws {
        let html = """
        <div>Session usage</div><div>12.5% used</div>
        <div>Weekly usage</div><div>40% used</div>
        """
        let quota = try OllamaUsageService.parse(html)
        #expect(quota.primary.usedPercent == 12.5)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.usedPercent == 40)
        #expect(quota.uniqueScopedWindows.isEmpty)
    }

    @Test("Ollama keeps all three windows regardless of HTML order")
    func ollamaThreeWindowsOrderIndependent() throws {
        let hourlyFirst = """
        <div>Hourly usage</div><div>80% used</div>
        <div>Session usage</div><div>12.5% used</div>
        <div>Weekly usage</div><div>40% used</div>
        """
        let hourlyLast = """
        <div>Session usage</div><div>12.5% used</div>
        <div>Weekly usage</div><div>40% used</div>
        <div>Hourly usage</div><div>80% used</div>
        """
        for html in [hourlyFirst, hourlyLast] {
            let quota = try OllamaUsageService.parse(html)
            // Session/Weekly 槽位维持现状;Hourly 一律 scoped,不抢主槽。
            #expect(quota.primary.usedPercent == 12.5)
            #expect(quota.primary.windowMinutes == 300)
            #expect(quota.secondary?.usedPercent == 40)
            #expect(quota.secondary?.windowMinutes == 10_080)
            let hourly = try #require(quota.uniqueScopedWindows.first)
            #expect(quota.uniqueScopedWindows.count == 1)
            #expect(hourly.scopeID == "ollama_hourly")
            #expect(hourly.displayName == "Hourly")
            #expect(hourly.window.usedPercent == 80)
            #expect(hourly.window.windowMinutes == 60)
            #expect(hourly.observedAt != nil)
        }
    }

    @Test("Ollama with only an hourly reading still yields a primary window")
    func ollamaHourlyOnly() throws {
        let quota = try OllamaUsageService.parse("<div>Hourly usage</div><div>80% used</div>")
        #expect(quota.primary.usedPercent == 80)
        #expect(quota.primary.windowMinutes == 60)
        #expect(quota.secondary == nil)
        #expect(quota.uniqueScopedWindows.isEmpty)
    }

    @Test("Secret store prefers environment variables and persists to keychain descriptor")
    func secretStoreEnv() {
        var store = ProviderSecretStore(provider: .deepseek)
        store.environment = ["DEEPSEEK_API_KEY": " sk-ds "]
        #expect(store.load() == "sk-ds")
        #expect(ProviderSecretStore.descriptor(for: .kiro) == nil)
        #expect(ProviderSecretStore.descriptors.count == 9)
        #expect(ProviderCredentialConfiguration.resolve(for: .zai)?.isCookie == false)
        #expect(ProviderCredentialConfiguration.resolve(for: .deepseek)?.isCookie == false)
        #expect(ProviderCredentialConfiguration.resolve(for: .mimo)?.isCookie == true)
        #expect(ProviderCredentialConfiguration.resolve(for: .claude) == nil)
    }

    @Test("Quota cache round-trips the dictionary format and reads legacy fields")
    func quotaCacheFormats() throws {
        let quota = ProviderQuota(
            provider: .kimi,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: Date(timeIntervalSince1970: 1_784_000_000),
            remainingBalance: QuotaBalance(amount: 12.34, currencyCode: "USD")
        )
        let snapshot = QuotaCache.Snapshot(byProvider: [.kimi: quota])
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QuotaCache.Snapshot.self, from: encoded)
        #expect(decoded.byProvider[.kimi]?.primary.usedPercent == 10)
        #expect(decoded.byProvider[.kimi]?.remainingBalance?.displayText == "$12.34")

        // v1 逐字段格式仍可读。
        let legacy = """
        {"claude": {"provider": "Claude Code",
                    "primary": {"usedPercent": 5, "windowMinutes": 300},
                    "capturedAt": 700000000}}
        """
        let migrated = try JSONDecoder().decode(QuotaCache.Snapshot.self, from: Data(legacy.utf8))
        #expect(migrated.byProvider[.claude]?.primary.usedPercent == 5)
        #expect(migrated.byProvider[.claude]?.remainingBalance == nil)
    }
}
