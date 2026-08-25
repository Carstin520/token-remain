import Foundation
import Testing
@testable import UsageDock

@Suite("Copilot usage parser")
struct CopilotUsageParserTests {
    @Test("Paid plan maps premium interactions to a monthly credits window")
    func paidPlan() throws {
        let payload = """
        {
          "copilot_plan": "copilot_pro",
          "quota_reset_date": "2026-08-01",
          "quota_snapshots": {
            "premium_interactions": {"entitlement": 300, "remaining": 120, "percent_remaining": 40.0},
            "chat": {"unlimited": true, "entitlement": -1},
            "completions": {"entitlement": -1}
          }
        }
        """
        let quota = try CopilotUsageParser.parse(Data(payload.utf8))
        #expect(quota.provider == .copilot)
        #expect(quota.primary.usedPercent == 60)
        #expect(quota.primary.windowMinutes == CopilotUsageParser.monthlyMinutes)
        #expect(quota.primary.resetsAt != nil)
        #expect(quota.primary.poolName == nil)
        #expect(quota.secondary == nil)
        #expect(quota.uniqueScopedWindows.isEmpty)
        #expect(quota.planName == "Copilot Pro")
        // 没有 overage_count 就没有超额消费行。
        #expect(quota.extraUsage == nil)
    }

    @Test("Paid plan overage count converts into an estimated pay-as-you-go spend")
    func paidPlanOverage() throws {
        let payload = """
        {
          "copilot_plan": "copilot_pro",
          "quota_reset_date": "2026-09-01",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300, "remaining": 0, "percent_remaining": 0.0,
              "overage_permitted": true, "overage_count": 25
            }
          }
        }
        """
        let quota = try CopilotUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 100)
        // 金额 = 次数 × $0.04(GitHub 公布单价),是推算不是账单;无金额上限字段。
        let extra = try #require(quota.extraUsage)
        #expect(extra == ExtraUsage(
            spentUSD: 25 * CopilotUsageParser.premiumOverageUnitPriceUSD,
            monthlyLimitUSD: nil
        ))
    }

    @Test("Zero or disallowed overage never renders a spend line")
    func overageBoundaries() throws {
        let zeroCount = """
        {
          "copilot_plan": "copilot_pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300, "remaining": 30, "overage_permitted": true, "overage_count": 0
            }
          }
        }
        """
        #expect(try CopilotUsageParser.parse(Data(zeroCount.utf8)).extraUsage == nil)

        let disallowed = """
        {
          "copilot_plan": "copilot_pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300, "remaining": 30, "overage_permitted": false, "overage_count": 3
            }
          }
        }
        """
        #expect(try CopilotUsageParser.parse(Data(disallowed.utf8)).extraUsage == nil)
    }

    @Test("Free plan promotes the busier pool to primary and scopes the sibling")
    func freePlan() throws {
        let payload = """
        {
          "copilot_plan": "free",
          "quota_reset_date": "2026-09-01",
          "quota_snapshots": {
            "chat": {"entitlement": 50, "remaining": 10},
            "completions": {"entitlement": 2000, "remaining": 1500}
          }
        }
        """
        let quota = try CopilotUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 80)
        #expect(quota.primary.poolName == CopilotUsageParser.chatPoolName)
        #expect(quota.primary.windowMinutes == CopilotUsageParser.monthlyMinutes)
        // 两个同时长的账户级窗口会触发手机同步的 duplicateWindow 拒收,兄弟池必须走 scoped。
        #expect(quota.secondary == nil)
        let scoped = try #require(quota.uniqueScopedWindows.first)
        #expect(quota.uniqueScopedWindows.count == 1)
        #expect(scoped.scopeID == CopilotUsageParser.completionsPoolScopeID)
        #expect(scoped.displayName == CopilotUsageParser.completionsPoolName)
        #expect(scoped.window.usedPercent == 25)
        #expect(scoped.window.windowMinutes == CopilotUsageParser.monthlyMinutes)
        #expect(scoped.observedAt != nil)
        // 两池共享同一个月度重置日。
        #expect(quota.primary.resetsAt != nil)
        #expect(scoped.window.resetsAt == quota.primary.resetsAt)
        // 免费档没有 premium overage 字段,不落超额消费行。
        #expect(quota.extraUsage == nil)
    }

    @Test("Free plan with busier completions flips the pools")
    func freePlanCompletionsBusier() throws {
        let payload = """
        {
          "copilot_plan": "free",
          "quota_snapshots": {
            "chat": {"entitlement": 50, "remaining": 45},
            "completions": {"entitlement": 2000, "remaining": 200}
          }
        }
        """
        let quota = try CopilotUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 90)
        #expect(quota.primary.poolName == CopilotUsageParser.completionsPoolName)
        #expect(quota.secondary == nil)
        let scoped = try #require(quota.uniqueScopedWindows.first)
        #expect(scoped.scopeID == CopilotUsageParser.chatPoolScopeID)
        #expect(scoped.displayName == CopilotUsageParser.chatPoolName)
        #expect(scoped.window.usedPercent == 10)
    }

    @Test("Free plan tie keeps chat as primary")
    func freePlanTiePrefersChat() throws {
        let payload = """
        {
          "copilot_plan": "free",
          "quota_snapshots": {
            "chat": {"entitlement": 100, "remaining": 60},
            "completions": {"entitlement": 2000, "remaining": 1200}
          }
        }
        """
        let quota = try CopilotUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 40)
        #expect(quota.primary.poolName == CopilotUsageParser.chatPoolName)
        let scoped = try #require(quota.uniqueScopedWindows.first)
        #expect(scoped.scopeID == CopilotUsageParser.completionsPoolScopeID)
    }

    @Test("Free plan with a single countable pool renders one plain window")
    func freePlanSinglePool() throws {
        let payload = """
        {
          "copilot_plan": "free",
          "quota_snapshots": {
            "chat": {"unlimited": true, "entitlement": -1},
            "completions": {"entitlement": 2000, "remaining": 500}
          }
        }
        """
        let quota = try CopilotUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 75)
        #expect(quota.primary.poolName == nil)
        #expect(quota.secondary == nil)
        #expect(quota.uniqueScopedWindows.isEmpty)
    }

    @Test("An org-managed seat with placeholder buckets is rejected with guidance")
    func orgSeatRejected() {
        let payload = """
        {"quota_snapshots": {"premium_interactions": {"entitlement": 0, "overage_permitted": true}}}
        """
        #expect(throws: (any Error).self) {
            try CopilotUsageParser.parse(Data(payload.utf8))
        }
    }

    @Test("Editor JSON and gh hosts.yml token extraction stay github.com-scoped")
    func tokenExtraction() {
        let apps = #"{"github.com:AppID": {"oauth_token": "gho_apps"}, "ghe.corp.com": {"oauth_token": "bad"}}"#
        #expect(CopilotTokenReader.token(fromEditorJSON: apps) == "gho_apps")
        #expect(CopilotTokenReader.token(fromEditorJSON: #"{"ghe.corp.com": {"oauth_token": "bad"}}"#) == nil)

        let yaml = """
        ghe.corp.com:
            oauth_token: bad_token
        github.com:
            user: octocat
            oauth_token: gho_yaml
        """
        #expect(CopilotTokenReader.yamlValue(yaml, key: "oauth_token") == "gho_yaml")
    }
}

@Suite("Devin usage parser")
struct DevinUsageParserTests {
    @Test("Daily and weekly remaining percents flip into used windows")
    func parsesDailyWeekly() throws {
        let payload = """
        {
          "userStatus": {
            "planStatus": {
              "planInfo": {"planName": "Core", "hideDailyQuota": false},
              "dailyQuotaRemainingPercent": 70,
              "weeklyQuotaRemainingPercent": 45,
              "dailyQuotaResetAtUnix": 1784005200,
              "weeklyQuotaResetAtUnix": 1784500000
            }
          }
        }
        """
        let quota = try DevinUsageParser.parse(Data(payload.utf8))
        #expect(quota.provider == .devin)
        #expect(quota.primary.usedPercent == 30)
        #expect(quota.primary.windowMinutes == 1_440)
        #expect(quota.secondary?.usedPercent == 55)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.planName == "Core")
    }

    @Test("hideDailyQuota drops the daily window; weekly becomes primary")
    func hiddenDaily() throws {
        let payload = """
        {
          "userStatus": {
            "planStatus": {
              "planInfo": {"hideDailyQuota": true},
              "dailyQuotaRemainingPercent": 70,
              "weeklyQuotaRemainingPercent": 45
            }
          }
        }
        """
        let quota = try DevinUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.secondary == nil)
    }

    @Test("TOML credential parsing reads windsurf_api_key")
    func tomlParsing() {
        let toml = """
        # devin credentials
        windsurf_api_key = "wk-123"
        api_server_url = "https://server.codeium.com/"
        """
        #expect(DevinAuthReader.tomlString(toml, key: "windsurf_api_key") == "wk-123")
        #expect(DevinAuthReader.cleanServerURL("https://server.codeium.com/") == "https://server.codeium.com")
        #expect(DevinAuthReader.cleanServerURL("http://insecure") == nil)
    }
}

@Suite("OpenRouter usage parser")
struct OpenRouterUsageParserTests {
    @Test("Credits usage maps to a lifetime (windowless) percent")
    func parsesCredits() throws {
        let payload = #"{"data": {"total_credits": 100, "total_usage": 37.5}}"#
        let quota = try OpenRouterUsageParser.parse(Data(payload.utf8), planName: "Pay As You Go")
        #expect(quota.provider == .openrouter)
        #expect(quota.primary.usedPercent == 37.5)
        #expect(quota.primary.windowMinutes == 0)
        #expect(quota.primary.resetsAt == nil)
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 62.5, currencyCode: "USD"))
        #expect(quota.primary.remainingBalance?.displayText == "$62.50")
        // 积分池自己就是 primary 时无需 scoped 复制。
        #expect(quota.uniqueScopedWindows.isEmpty)
        #expect(quota.planName == "Pay As You Go")
    }

    @Test("Zero purchased credits is a real depleted balance")
    func zeroCredits() throws {
        let quota = try OpenRouterUsageParser.parse(
            Data(#"{"data": {"total_credits": 0, "total_usage": 0}}"#.utf8)
        )
        #expect(quota.primary.usedPercent == 100)
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 0, currencyCode: "USD"))
    }

    @Test("Key limit, credits, plan, and spend buckets are preserved together")
    func parsesKeyDetails() throws {
        let credits = Data(#"{"data": {"total_credits": 100, "total_usage": 25}}"#.utf8)
        let key = Data(#"{"data": {"limit": 40, "usage": 10, "limit_remaining": 30, "limit_reset": "weekly", "is_free_tier": false, "usage_daily": 1.5, "usage_weekly": 4, "usage_monthly": 9}}"#.utf8)
        let quota = try OpenRouterUsageParser.parse(creditsData: credits, keyData: key)
        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 30, currencyCode: "USD"))
        #expect(quota.secondary?.windowMinutes == 0)
        #expect(quota.secondary?.remainingBalance == QuotaBalance(amount: 75, currencyCode: "USD"))
        // 有周期的 key 限额维持现状:积分池走 secondary,不需要 scoped 行。
        #expect(quota.uniqueScopedWindows.isEmpty)
        #expect(quota.planName == "Pay As You Go")
        #expect(quota.spend == ProviderSpend(todayUSD: 1.5, weekUSD: 4, monthUSD: 9, allTimeUSD: 10))
    }

    @Test("A key limit without cadence keeps the credits pool as a scoped percent row")
    func avoidsDuplicateLifetimeWindows() throws {
        let credits = Data(#"{"data":{"total_credits":20,"total_usage":5}}"#.utf8)
        let key = Data(#"{"data":{"limit":10,"usage":2}}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let quota = try OpenRouterUsageParser.parse(creditsData: credits, keyData: key, now: now)
        #expect(quota.primary.windowMinutes == 0)
        #expect(quota.primary.usedPercent == 20)
        // 同为 0 分钟的积分池不进 secondary(手机同步拒收同时长账户级双窗),
        // 也不再降级成纯 accountBalance:scoped 行同时保住百分比和余额。
        #expect(quota.secondary == nil)
        #expect(quota.accountBalance == nil)
        let scoped = try #require(quota.uniqueScopedWindows.first)
        #expect(quota.uniqueScopedWindows.count == 1)
        #expect(scoped.scopeID == OpenRouterUsageParser.creditsScopeID)
        #expect(scoped.displayName == OpenRouterUsageParser.creditsDisplayName)
        #expect(scoped.window.usedPercent == 25)
        #expect(scoped.window.windowMinutes == 0)
        #expect(scoped.window.remainingBalance == QuotaBalance(amount: 15, currencyCode: "USD"))
        #expect(scoped.observedAt == now)
    }

    @Test("The zero-minute window renders as a lifetime label")
    func lifetimeWindowName() {
        #expect(UsageFormatting.windowName(minutes: 0) == L10n.text("duration.total"))
    }
}

@Suite("Antigravity usage parser")
struct AntigravityUsageParserTests {
    @Test("Gemini pools map to session and weekly windows")
    func parsesPools() throws {
        let payload = """
        {
          "response": {
            "groups": [
              {"buckets": [
                {"bucketId": "gemini-5h", "remainingFraction": 0.8, "resetTime": "2026-07-22T02:00:00Z"},
                {"bucketId": "gemini-weekly", "remainingFraction": 0.4},
                {"bucketId": "3p-5h", "remainingFraction": 0.9},
                {"bucketId": "3p-weekly", "remainingFraction": 0.7}
              ]}
            ]
          }
        }
        """
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let quota = try AntigravityUsageParser.parse(Data(payload.utf8), now: now)
        #expect(quota.provider == .antigravity)
        #expect(abs(quota.primary.usedPercent - 20) < 0.0001)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt != nil)
        #expect(abs((quota.secondary?.usedPercent ?? 0) - 60) < 0.0001)
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == [
            "antigravity_3p_5h",
            "antigravity_3p_weekly"
        ])
        let scopedUsage = quota.uniqueScopedWindows.map(\.window.usedPercent)
        #expect(abs(scopedUsage[0] - 10) < 0.0001)
        #expect(abs(scopedUsage[1] - 30) < 0.0001)
        // observedAt 必须落在 3P 行上:一次刷新只回 gemini 桶时,缺时间戳
        // 的 scoped 行会被 retainingActiveScopedWindows 当作过期清掉。
        #expect(quota.uniqueScopedWindows.allSatisfy { $0.observedAt == now })
    }

    @Test("Unknown bucket IDs are skipped instead of guessing a window")
    func skipsUnknownBuckets() throws {
        let payload = """
        {
          "groups": [
            {"buckets": [
              {"bucketId": "gemini-5h", "remainingFraction": 0.5},
              {"bucketId": "mystery-pool", "remainingFraction": 0.25},
              {"bucketId": "mystery-weekly", "remainingFraction": 0.75}
            ]}
          ]
        }
        """
        let quota = try AntigravityUsageParser.parse(Data(payload.utf8))
        #expect(abs(quota.primary.usedPercent - 50) < 0.0001)
        #expect(quota.secondary == nil)
        #expect(quota.uniqueScopedWindows.isEmpty)
    }

    @Test("Keychain payload decoding handles agy JSON and bearer fallbacks")
    func tokenDecoding() {
        let agy = #"{"token": {"access_token": "ya29.abc", "expiry": "2026-07-22T00:00:00Z"}}"#
        let parsed = AntigravityTokenReader.parse(agy)
        #expect(parsed?.accessToken == "ya29.abc")
        #expect(parsed?.expiry != nil)
        #expect(AntigravityTokenReader.parse("Bearer raw-token")?.accessToken == "raw-token")
        #expect(AntigravityTokenReader.parse("{broken json") == nil)
        #expect(GoKeyring.unwrap("go-keyring-base64:" + Data("hello".utf8).base64EncodedString()) == "hello")
    }

    @Test("Local process discovery accepts Antigravity 2.x and ignores unrelated servers")
    func localProcessDiscovery() {
        let listing = """
          101 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token secret-a --app_data_dir antigravity
          102 /tmp/language_server --csrf_token unrelated --app_data_dir another-app
          103 /Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir=antigravity --csrf_token=secret-b
        """
        let processes = AntigravityLocalUsageProbe.parseProcesses(listing)
        #expect(processes == [
            .init(pid: 101, csrfToken: "secret-a"),
            .init(pid: 103, csrfToken: "secret-b")
        ])
    }

    @Test("Local lsof output is reduced to unique listening ports")
    func localPortDiscovery() {
        let listing = """
        language 101 user 20u IPv4 0t0 TCP 127.0.0.1:60735 (LISTEN)
        language 101 user 21u IPv4 0t0 TCP 127.0.0.1:60734 (LISTEN)
        language 101 user 22u IPv4 0t0 TCP 127.0.0.1:60735 (LISTEN)
        """
        #expect(AntigravityLocalUsageProbe.parseListeningPorts(listing) == [60734, 60735])
    }

    @Test("Probe failures preserve whether Antigravity is running")
    func probeFailureDisposition() {
        #expect(
            AntigravityUsageService.fallbackDisposition(
                for: AntigravityLocalUsageProbe.ProbeError.processUnavailable
            ) == .notDetected
        )
        #expect(
            AntigravityUsageService.fallbackDisposition(
                for: AntigravityLocalUsageProbe.ProbeError.portUnavailable
            ) == .runningButQuotaUnavailable
        )
        #expect(
            AntigravityUsageService.fallbackDisposition(
                for: AntigravityLocalUsageProbe.ProbeError.quotaUnavailable
            ) == .runningButQuotaUnavailable
        )
        #expect(
            AntigravityUsageService.fallbackDisposition(for: CancellationError()) == .notDetected
        )
    }

    @Test("Antigravity service errors use provider-specific recovery guidance")
    func providerSpecificErrorDescriptions() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let englishBundle = try #require(
            Bundle(
                path: sourceRoot
                    .appendingPathComponent("Sources/UsageDock/Localization/en.lproj")
                    .path
            )
        )

        #expect(
            AntigravityUsageService.ServiceError.runningButQuotaUnavailable
                .description(bundle: englishBundle)
                == "Antigravity is running but its local quota service returned no data; update Antigravity to the latest version and try again"
        )
        #expect(
            AntigravityUsageService.ServiceError.notLoggedIn
                .description(bundle: englishBundle)
                == "Antigravity not detected; open Antigravity and keep it running so TokenRemain can read its local quota service"
        )
    }
}

@Suite("OpenCode usage math")
struct OpenCodeUsageMathTests {
    @Test("Session and weekly spend map to the published Go caps")
    func windowMath() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let nowMs = now.timeIntervalSince1970 * 1000
        let costs: [(ms: Double, cost: Double)] = [
            (nowMs - 3_600_000, 3.0),        // 1 小时前:会话 + 周
            (nowMs - 6 * 3_600_000, 6.0)     // 6 小时前:仅周(若同周)
        ]
        let quota = OpenCodeUsageService.quota(costs: costs, now: now)
        #expect(quota.provider == .opencode)
        #expect(abs(quota.primary.usedPercent - 3.0 / 12 * 100) < 0.0001)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt != nil)
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 9, currencyCode: "USD"))
        #expect(quota.secondary != nil)
        #expect(quota.secondary?.remainingBalance == QuotaBalance(amount: 21, currencyCode: "USD"))
        let monthly = quota.scopedWindows?.first(where: { $0.scopeID == "opencode_monthly" })
        #expect(monthly?.window.remainingBalance == QuotaBalance(amount: 51, currencyCode: "USD"))
        #expect(monthly?.window.resetsAt != nil)
        #expect(quota.planName == "Go")
    }

    @Test("sqlite JSON rows parse into cost samples")
    func rowParsing() {
        let output = Data("[[1784000000000, 1.25], [1784000100000, 0.5], [null, 1]]".utf8)
        let rows = OpenCodeUsageService.parseRows(output)
        #expect(rows.count == 2)
        #expect(rows[0].cost == 1.25)
    }

    @Test("Anchored monthly boundaries retain the subscription day")
    func anchoredMonth() {
        let anchor = Date(timeIntervalSince1970: 1_766_243_700) // 2025-12-20 12:35 UTC
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let bounds = OpenCodeUsageService.monthBounds(
            nowMs: now.timeIntervalSince1970 * 1000,
            anchorMs: anchor.timeIntervalSince1970 * 1000
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.day, from: Date(timeIntervalSince1970: bounds.startMs / 1000)) == 20)
        #expect(calendar.component(.day, from: Date(timeIntervalSince1970: bounds.endMs / 1000)) == 20)
    }

    @Test("An idle session has no moving synthetic reset timestamp")
    func idleSessionReset() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let quota = OpenCodeUsageService.quota(
            costs: [(now.timeIntervalSince1970 * 1000 - 8 * 3_600_000, 2)],
            now: now
        )
        #expect(quota.primary.resetsAt == nil)
    }
}
