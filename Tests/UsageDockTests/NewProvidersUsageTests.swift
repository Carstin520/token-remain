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
        #expect(quota.secondary == nil)
        #expect(quota.planName == "Copilot Pro")
    }

    @Test("Free plan falls back to chat and completions buckets")
    func freePlan() throws {
        let payload = """
        {
          "copilot_plan": "free",
          "quota_snapshots": {
            "chat": {"entitlement": 50, "remaining": 10},
            "completions": {"entitlement": 2000, "remaining": 1500}
          }
        }
        """
        let quota = try CopilotUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 80)
        #expect(quota.secondary?.usedPercent == 25)
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
        #expect(quota.planName == "Pay As You Go")
    }

    @Test("Zero purchased credits is a guidance error, not a fake meter")
    func zeroCredits() {
        #expect(throws: (any Error).self) {
            try OpenRouterUsageParser.parse(Data(#"{"data": {"total_credits": 0, "total_usage": 0}}"#.utf8))
        }
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
                {"bucketId": "3p-5h", "remainingFraction": 0.9}
              ]}
            ]
          }
        }
        """
        let quota = try AntigravityUsageParser.parse(Data(payload.utf8))
        #expect(quota.provider == .antigravity)
        #expect(abs(quota.primary.usedPercent - 20) < 0.0001)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt != nil)
        #expect(abs((quota.secondary?.usedPercent ?? 0) - 60) < 0.0001)
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
        #expect(quota.secondary != nil)
        #expect(quota.planName == "Go")
    }

    @Test("sqlite JSON rows parse into cost samples")
    func rowParsing() {
        let output = Data("[[1784000000000, 1.25], [1784000100000, 0.5], [null, 1]]".utf8)
        let rows = OpenCodeUsageService.parseRows(output)
        #expect(rows.count == 2)
        #expect(rows[0].cost == 1.25)
    }
}
