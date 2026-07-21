import Foundation
import Testing
@testable import UsageDock

@Suite("Codex wham/usage parser")
struct CodexAPIUsageParserTests {
    @Test("Parses the standard session plus weekly window pair")
    func parsesBothWindows() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {"used_percent": 12.3, "limit_window_seconds": 18000, "reset_at": 1784005200},
            "secondary_window": {"used_percent": 55, "limit_window_seconds": 604800, "reset_after_seconds": 3600}
          }
        }
        """
        let quota = try CodexAPIUsageParser.parse(Data(payload.utf8), now: now)

        #expect(quota.provider == .codex)
        #expect(quota.primary.usedPercent == 12.3)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_784_005_200))
        #expect(quota.secondary?.usedPercent == 55)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.secondary?.resetsAt == now.addingTimeInterval(3600))
        #expect(quota.planName == "Pro 20x")
    }

    @Test("A weekly limit parked in the primary slot is classified by duration")
    func weeklyInPrimarySlot() throws {
        let payload = """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 71, "limit_window_seconds": 604800}
          }
        }
        """
        let quota = try CodexAPIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 71)
        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.secondary == nil)
    }

    @Test("Windows without explicit durations keep the historical slot mapping")
    func slotFallbackWithoutDurations() throws {
        let payload = """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 10},
            "secondary_window": {"used_percent": 20}
          }
        }
        """
        let quota = try CodexAPIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 10)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.usedPercent == 20)
        #expect(quota.secondary?.windowMinutes == 10_080)
    }

    @Test("A response without any usable window is rejected for snapshot fallback")
    func missingWindowsThrows() {
        #expect(throws: (any Error).self) {
            try CodexAPIUsageParser.parse(Data(#"{"plan_type": "pro"}"#.utf8))
        }
    }

    @Test("Plan names map to Codex product wording")
    func planNames() {
        #expect(CodexAPIUsageParser.planName("prolite") == "Pro 5x")
        #expect(CodexAPIUsageParser.planName("pro") == "Pro 20x")
        #expect(CodexAPIUsageParser.planName("plus") == "Plus")
        #expect(CodexAPIUsageParser.planName("team_plan") == "Team Plan")
        #expect(CodexAPIUsageParser.planName(nil) == nil)
    }
}

@Suite("Codex auth reader")
struct CodexAuthReaderTests {
    @Test("Parses tokens and account id from auth.json")
    func parsesAuthFile() {
        let payload = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "\(fakeJWT(exp: 9_999_999_999))",
            "refresh_token": "rt-test",
            "account_id": "acct-123"
          },
          "last_refresh": "2026-07-21T00:00:00Z"
        }
        """
        let auth = CodexAuthReader.parse(Data(payload.utf8))
        #expect(auth?.accountID == "acct-123")
        #expect(auth?.accessTokenExpiry == Date(timeIntervalSince1970: 9_999_999_999))
    }

    @Test("An API-key-only auth.json yields no usable auth")
    func apiKeyOnlyIsRejected() {
        let payload = #"{"OPENAI_API_KEY": "sk-test", "tokens": null}"#
        #expect(CodexAuthReader.parse(Data(payload.utf8)) == nil)
    }

    @Test("JWT expiry claim survives base64url padding variants")
    func jwtExpiryParsing() {
        #expect(CodexAuthReader.jwtExpiry(fakeJWT(exp: 1_784_000_000)) == Date(timeIntervalSince1970: 1_784_000_000))
        #expect(CodexAuthReader.jwtExpiry("not-a-jwt") == nil)
    }

    @Test("CODEX_HOME overrides the default auth.json location")
    func codexHomeOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = #"{"tokens": {"access_token": "abc.def.ghi", "account_id": "acct-9"}}"#
        try Data(payload.utf8).write(to: directory.appendingPathComponent("auth.json"))

        var reader = CodexAuthReader()
        reader.environment = ["CODEX_HOME": directory.path]
        #expect(reader.load()?.accountID == "acct-9")
    }
}

private func fakeJWT(exp: Double) -> String {
    let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncoded()
    let payload = Data(#"{"exp": \#(exp)}"#.utf8).base64URLEncoded()
    return "\(header).\(payload).sig"
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
