import Foundation
import Security
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
          "rate_limit_reset_credits": {
            "available_count": 3,
            "applicable_available_count": 2
          },
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
        #expect(quota.codexResetCredits == CodexRateLimitResetCredits(
            availableCount: 3,
            applicableAvailableCount: 2
        ))
        #expect(quota.mergingScopedWindows([]).codexResetCredits == quota.codexResetCredits)
    }

    @Test("Reset credit counts accept numeric strings and clamp invalid ranges")
    func resetCredits() {
        #expect(
            CodexAPIUsageParser.resetCredits([
                "available_count": "2",
                "applicable_available_count": 9
            ]) == CodexRateLimitResetCredits(
                availableCount: 2,
                applicableAvailableCount: 2
            )
        )
        #expect(
            CodexAPIUsageParser.resetCredits([
                "available_count": -3,
                "applicable_available_count": -1
            ]) == CodexRateLimitResetCredits(
                availableCount: 0,
                applicableAvailableCount: 0
            )
        )
        #expect(CodexAPIUsageParser.resetCredits([:]) == nil)
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

    @Test("Falls through to the Codex keychain when auth.json is absent")
    func keychainFallback() {
        var reader = CodexAuthReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-codex-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { account, interaction in
            #expect(account.hasPrefix("cli|"))
            #expect(account.count == 20)
            #expect(interaction == .disallowed)
            return KeychainRead.Outcome(
                payload: #"{"tokens":{"access_token":"abc.def.ghi","account_id":"acct-keychain"}}"#,
                status: errSecSuccess
            )
        }

        let result = reader.read()
        #expect(result.auth?.accountID == "acct-keychain")
        #expect(result.source == .keychain)
        #expect(result.keychainStatus == errSecSuccess)
    }

    @Test("A valid auth.json wins without touching another app's keychain")
    func filePrecedesKeychain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-codex-file-first-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"tokens":{"access_token":"abc.def.ghi","account_id":"acct-file"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))

        var reader = CodexAuthReader()
        reader.environment = ["CODEX_HOME": directory.path]
        reader.keychainPayload = { _, _ in
            Issue.record("keychain must not be consulted while auth.json is usable")
            return KeychainRead.Outcome(payload: nil, status: errSecItemNotFound)
        }

        let result = reader.read()
        #expect(result.auth?.accountID == "acct-file")
        #expect(result.source == .file)
        #expect(result.keychainStatus == nil)
    }

    @Test("An expired auth.json yields to a fresh Codex keychain credential")
    func expiredFileYieldsToKeychain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-codex-expired-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = fakeJWT(exp: 1_700_000_000)
        try Data(#"{"tokens":{"access_token":"\#(expired)","account_id":"acct-expired"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))

        var reader = CodexAuthReader()
        reader.environment = ["CODEX_HOME": directory.path]
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(
                payload: #"{"tokens":{"access_token":"\#(fakeJWT(exp: 1_900_000_000))","account_id":"acct-fresh"}}"#,
                status: errSecSuccess
            )
        }

        let result = reader.read(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(result.auth?.accountID == "acct-fresh")
        #expect(result.source == .keychain)
    }

    @Test("A malformed auth.json also falls through to the Codex keychain")
    func malformedFileYieldsToKeychain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-codex-malformed-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("auth.json"))

        var reader = CodexAuthReader()
        reader.environment = ["CODEX_HOME": directory.path]
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(
                payload: #"{"tokens":{"access_token":"abc.def.ghi","account_id":"acct-keychain"}}"#,
                status: errSecSuccess
            )
        }
        #expect(reader.read().source == .keychain)
    }

    @Test("An explicit user action may allow Codex keychain interaction")
    func explicitKeychainAuthorization() {
        let observed = LockedValue<KeychainRead.Interaction?>(nil)
        var reader = CodexAuthReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-codex-authorize-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _, interaction in
            observed.set(interaction)
            return KeychainRead.Outcome(payload: nil, status: errSecAuthFailed)
        }

        let result = reader.read(keychainInteraction: .allowed)
        #expect(observed.get() == .allowed)
        #expect(result.auth == nil)
        #expect(result.needsAuthorization)
    }

    @Test("A suppressed prompt is surfaced as requiring explicit authorization")
    func suppressedPromptNeedsAuthorization() {
        var reader = CodexAuthReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-codex-auth-required")
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
        #expect(reader.read().needsAuthorization)
    }

    @Test("A readable but unknown Codex keychain schema is classified as invalid")
    func invalidKeychainPayload() {
        var reader = CodexAuthReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-codex-invalid-payload")
        reader.keychainPayload = { _, _ in
            KeychainRead.Outcome(payload: #"{"future_schema":true}"#, status: errSecSuccess)
        }
        let result = reader.read()
        #expect(result.auth == nil)
        #expect(result.source == nil)
        #expect(result.hasInvalidKeychainPayload)
        #expect(!result.needsAuthorization)
    }

    @Test("Codex keychain account is stable for a normalized CODEX_HOME")
    func stableKeychainAccount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-codex-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var first = CodexAuthReader()
        first.environment = ["CODEX_HOME": directory.path]
        var second = CodexAuthReader()
        second.environment = ["CODEX_HOME": directory.appending(path: ".").path]

        #expect(first.keychainAccount() == second.keychainAccount())
        #expect(first.keychainAccount().hasPrefix("cli|"))
        #expect(first.keychainAccount().count == 20)
    }

    @Test("Codex keychain account matches the upstream SHA-256 golden vector")
    func keychainAccountGoldenVector() {
        var reader = CodexAuthReader()
        reader.environment = ["CODEX_HOME": "/tmp/tokenremain-codex-home-fixture"]
        #expect(reader.keychainAccount() == "cli|c3c75cdbc51596f5")
    }

    @Test("A symlinked CODEX_HOME hashes its canonical destination")
    func symlinkedCodexHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-codex-symlink-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appending(path: "real")
        let link = root.appending(path: "alias")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        defer { try? FileManager.default.removeItem(at: root) }

        var destinationReader = CodexAuthReader()
        destinationReader.environment = ["CODEX_HOME": destination.path]
        var linkReader = CodexAuthReader()
        linkReader.environment = ["CODEX_HOME": link.path]
        #expect(linkReader.keychainAccount() == destinationReader.keychainAccount())
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
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
