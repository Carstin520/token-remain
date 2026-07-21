import Foundation
import Testing
@testable import UsageDock

@Suite("Cursor usage parser")
struct CursorAPIUsageParserTests {
    @Test("Parses the new billing model with totalPercentUsed and real cycle")
    func parsesPercentBasedUsage() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let start = 1_782_000_000_000.0
        let end = 1_784_592_000_000.0
        let payload = """
        {
          "enabled": true,
          "planUsage": {"totalPercentUsed": 42.5, "limit": 2000, "totalSpend": 850},
          "billingCycleStart": \(start),
          "billingCycleEnd": \(end)
        }
        """
        let quota = try CursorAPIUsageParser.parse(Data(payload.utf8), planName: "pro", now: now)

        #expect(quota.provider == .cursor)
        #expect(quota.primary.usedPercent == 42.5)
        #expect(quota.primary.windowMinutes == Int((end - start) / 1000 / 60))
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: end / 1000))
        #expect(quota.secondary == nil)
        #expect(quota.planName == "Pro")
        #expect(quota.capturedAt == now)
    }

    @Test("Falls back to totalSpend over limit when the percent field is absent")
    func computesPercentFromSpend() throws {
        let payload = """
        {"enabled": true, "planUsage": {"limit": 2000, "totalSpend": 500}}
        """
        let quota = try CursorAPIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.windowMinutes == CursorAPIUsageParser.defaultCycleMinutes)
        #expect(quota.primary.resetsAt == nil)
    }

    @Test("Derives spend from remaining when totalSpend is absent")
    func computesPercentFromRemaining() throws {
        let payload = """
        {"enabled": true, "planUsage": {"limit": 1000, "remaining": 400}}
        """
        let quota = try CursorAPIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 60)
    }

    @Test("A disabled account is rejected as no active subscription")
    func disabledAccountThrows() {
        let payload = #"{"enabled": false, "planUsage": {"totalPercentUsed": 10}}"#
        #expect(throws: (any Error).self) {
            try CursorAPIUsageParser.parse(Data(payload.utf8))
        }
    }

    @Test("A payload without usable plan usage is rejected")
    func missingPlanUsageThrows() {
        #expect(throws: (any Error).self) {
            try CursorAPIUsageParser.parse(Data(#"{"enabled": true}"#.utf8))
        }
    }

    @Test("Used percent is clamped into 0...100")
    func clampsPercent() throws {
        let payload = #"{"enabled": true, "planUsage": {"totalPercentUsed": 130}}"#
        let quota = try CursorAPIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 100)
    }

    @Test("Membership types render as title-cased plan pills")
    func planLabels() {
        #expect(CursorAPIUsageParser.planLabel("pro") == "Pro")
        #expect(CursorAPIUsageParser.planLabel("free trial") == "Free Trial")
        #expect(CursorAPIUsageParser.planLabel("  ") == nil)
        #expect(CursorAPIUsageParser.planLabel(nil) == nil)
    }
}

@Suite("Cursor auth reader")
struct CursorAuthReaderTests {
    @Test("state.vscdb values are unwrapped from optional JSON quoting")
    func normalizesStateValues() {
        #expect(CursorAuthReader.normalized("  token-abc \n") == "token-abc")
        #expect(CursorAuthReader.normalized("\"token-abc\"") == "token-abc")
        #expect(CursorAuthReader.normalized("\"\"") == nil)
        #expect(CursorAuthReader.normalized("") == nil)
        #expect(CursorAuthReader.normalized(nil) == nil)
    }

    @Test("Keychain fallback is used when no state database exists")
    func keychainFallback() async {
        var reader = CursorAuthReader()
        reader.stateDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-cursor-missing-\(UUID().uuidString).vscdb")
        reader.keychainPayload = { "kc-token" }
        let auth = await reader.load()
        #expect(auth?.accessToken == "kc-token")
        #expect(auth?.membershipType == nil)
    }

    @Test("No credential source yields nil instead of a bogus auth")
    func missingEverythingYieldsNil() async {
        var reader = CursorAuthReader()
        reader.stateDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-cursor-missing-\(UUID().uuidString).vscdb")
        reader.keychainPayload = { nil }
        let auth = await reader.load()
        #expect(auth == nil)
    }

    @Test("Reads token and membership from a real state database")
    func readsFromSQLite() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-cursor-\(UUID().uuidString).vscdb").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await ProcessRunner.run("/usr/bin/sqlite3", arguments: [
            path,
            """
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'db-token');
            INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', 'pro');
            """
        ])

        var reader = CursorAuthReader()
        reader.stateDBURL = URL(fileURLWithPath: path)
        reader.keychainPayload = {
            Issue.record("keychain must not be consulted when the state db answers")
            return nil
        }
        let auth = await reader.load()
        #expect(auth?.accessToken == "db-token")
        #expect(auth?.membershipType == "pro")
    }
}
