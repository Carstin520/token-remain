import Foundation
import Security
import Testing
@testable import UsageDock

@Suite("Claude oauth/usage parser")
struct ClaudeOAuthUsageParserTests {
    @Test("Parses five hour and seven day windows with ISO reset times")
    func parsesBothWindows() throws {
        let payload = """
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2026-07-21T12:00:00Z"},
          "seven_day": {"utilization": 40, "resets_at": "2026-07-24T13:00:00.000Z"}
        }
        """
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let quota = try ClaudeOAuthUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            now: now
        )

        #expect(quota.provider == .claude)
        #expect(quota.primary.usedPercent == 12.5)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt == ISO8601DateFormatter().date(from: "2026-07-21T12:00:00Z"))
        #expect(quota.secondary?.usedPercent == 40)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.planName == "Max 20x")
        #expect(quota.capturedAt == now)
    }

    @Test("Freshly reset window keeps nil reset date instead of inventing one")
    func missingResetStaysNil() throws {
        let payload = """
        {"five_hour": {"utilization": 0, "resets_at": null}}
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 0)
        #expect(quota.primary.resetsAt == nil)
        #expect(quota.secondary == nil)
    }

    @Test("Epoch reset timestamps are accepted in seconds and milliseconds")
    func epochResets() throws {
        let payload = """
        {
          "five_hour": {"utilization": 5, "resets_at": 1784005200},
          "seven_day": {"utilization": 9, "resets_at": 1784005200000}
        }
        """
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        let expected = Date(timeIntervalSince1970: 1_784_005_200)
        #expect(quota.primary.resetsAt == expected)
        #expect(quota.secondary?.resetsAt == expected)
    }

    @Test("A payload without the five hour window is rejected for PTY fallback")
    func missingFiveHourThrows() {
        let payload = #"{"seven_day": {"utilization": 40}}"#
        #expect(throws: (any Error).self) {
            try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        }
    }

    @Test("Utilization is clamped into 0...100")
    func clampsUtilization() throws {
        let payload = #"{"five_hour": {"utilization": 120}}"#
        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 100)
    }

    @Test("Plan name falls back to bare subscription type without a tier")
    func planNameWithoutTier() {
        #expect(ClaudeOAuthUsageParser.planName(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        #expect(ClaudeOAuthUsageParser.planName(subscriptionType: nil, rateLimitTier: "20x") == nil)
        #expect(ClaudeOAuthUsageParser.planName(subscriptionType: "max", rateLimitTier: "default_5x") == "Max 5x")
    }
}

@Suite("Claude credentials reader")
struct ClaudeCredentialsReaderTests {
    @Test("Parses Claude Code credentials JSON")
    func parsesCredentials() {
        let payload = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-test",
            "refreshToken": "sk-ant-ort01-test",
            "expiresAt": 9999999999999,
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """
        let credentials = ClaudeCredentialsReader.parse(payload)
        #expect(credentials?.accessToken == "sk-ant-oat01-test")
        #expect(credentials?.subscriptionType == "max")
        #expect(credentials?.rateLimitTier == "default_claude_max_20x")
    }

    @Test("An expired token is skipped instead of being sent to the API")
    func skipsExpiredToken() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let expiredMs = (now.timeIntervalSince1970 + 30) * 1000
        let payload = """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat01-test", "expiresAt": \(expiredMs)}}
        """
        #expect(ClaudeCredentialsReader.parse(payload, now: now) == nil)
    }

    @Test("A token without expiresAt is accepted as-is")
    func acceptsTokenWithoutExpiry() {
        let payload = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-test"}}"#
        #expect(ClaudeCredentialsReader.parse(payload)?.accessToken == "sk-ant-oat01-test")
    }

    @Test("Reads the credentials file from CLAUDE_CONFIG_DIR before the keychain")
    func readsConfigDirFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-file"}}"#
        try Data(payload.utf8).write(to: directory.appendingPathComponent(".credentials.json"))

        var reader = ClaudeCredentialsReader()
        reader.environment = ["CLAUDE_CONFIG_DIR": directory.path]
        reader.keychainPayload = { _ in
            Issue.record("keychain must not be consulted when the file already answers")
            return KeychainRead.Outcome(payload: nil, status: errSecItemNotFound)
        }
        #expect(reader.load()?.accessToken == "sk-ant-oat01-file")
    }

    @Test("Falls through to the keychain when no credentials file exists")
    func fallsBackToKeychain() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _ in
            KeychainRead.Outcome(
                payload: #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-keychain"}}"#,
                status: errSecSuccess
            )
        }
        #expect(reader.load()?.accessToken == "sk-ant-oat01-keychain")
    }

    /// 这两个只验证"意图有没有传到 KeychainRead 门口"。禁止交互究竟有没有生效
    /// 是 `KeychainReadTests` 的职责 —— 上一版回归时,恰恰是这一层全绿而那一层
    /// 根本没被测到。
    @Test("Background fallback asks for a non-interactive keychain read")
    func backgroundFallbackIsNoninteractive() {
        let observed = ClaudeLockedValue<KeychainRead.Interaction?>(nil)
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { interaction in
            observed.set(interaction)
            return KeychainRead.Outcome(
                payload: #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-keychain"}}"#,
                status: errSecSuccess
            )
        }

        #expect(reader.load()?.accessToken == "sk-ant-oat01-keychain")
        #expect(observed.get() == .disallowed)
    }

    @Test("An explicit user action may opt into Keychain interaction")
    func explicitActionCanAllowInteraction() {
        let observed = ClaudeLockedValue<KeychainRead.Interaction?>(nil)
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { interaction in
            observed.set(interaction)
            return KeychainRead.Outcome(
                payload: #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-keychain"}}"#,
                status: errSecSuccess
            )
        }

        #expect(
            reader.load(keychainInteraction: .allowed)?.accessToken
                == "sk-ant-oat01-keychain"
        )
        #expect(observed.get() == .allowed)
    }

    /// 凭据不可用时 `fetch()` 必须抛错让 `ClaudeUsageService` 走 PTY 兜底,
    /// 而不是把刷新任务卡在钥匙串上。
    @Test("Unavailable credentials surface as nil so the fallback chain can engage")
    func unavailableCredentialsYieldNil() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _ in
            KeychainRead.Outcome(payload: nil, status: errSecItemNotFound)
        }
        #expect(reader.load() == nil)
    }

    @Test("A blocked Claude keychain item requests explicit authorization")
    func keychainAuthorizationStatus() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-claude-auth-required")
        reader.keychainPayload = { _ in
            KeychainRead.Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
        let result = reader.read()
        #expect(result.credentials == nil)
        #expect(result.needsAuthorization)
    }

    @Test("A readable unknown Claude keychain schema is classified as invalid")
    func invalidKeychainSchema() {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-claude-invalid")
        reader.keychainPayload = { _ in
            KeychainRead.Outcome(payload: #"{"future":true}"#, status: errSecSuccess)
        }
        let result = reader.read()
        #expect(result.credentials == nil)
        #expect(result.hasInvalidKeychainPayload)
        #expect(!result.needsAuthorization)
    }

    @Test("An expired readable Claude credential is not called malformed")
    func expiredKeychainCredential() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let expiredMs = (now.timeIntervalSince1970 - 60) * 1000
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = URL(fileURLWithPath: "/tmp/tokenremain-claude-expired")
        reader.keychainPayload = { _ in
            KeychainRead.Outcome(
                payload: #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":\#(expiredMs)}}"#,
                status: errSecSuccess
            )
        }
        let result = reader.read(now: now)
        #expect(result.credentials == nil)
        #expect(result.hasExpiredCredentials)
        #expect(!result.hasInvalidKeychainPayload)
    }
}

private final class ClaudeLockedValue<Value>: @unchecked Sendable {
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
