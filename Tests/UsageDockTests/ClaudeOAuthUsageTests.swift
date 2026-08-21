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

    @Test("Parses model-scoped weekly windows such as Fable")
    func parsesFableWindow() throws {
        let payload = """
        {
          "five_hour": {"utilization": 12.5},
          "seven_day": {"utilization": 40},
          "seven_day_fable": {"utilization": 67, "resets_at": "2026-07-24T13:00:00Z"}
        }
        """

        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        let fable = try #require(quota.scopedWindows?.first)
        #expect(fable.scopeID == "fable")
        #expect(fable.displayName == "Fable")
        #expect(fable.window.usedPercent == 67)
        #expect(fable.window.windowMinutes == 10_080)
    }

    @Test("Parses Fable from the structured limits schema when the legacy key is absent")
    func parsesStructuredLimitsFableWindow() throws {
        let payload = """
        {
          "limits": [
            {"kind":"session","group":"session","percent":7,"resets_at":"2026-08-13T04:00:00Z"},
            {"kind":"weekly_all","group":"weekly","percent":57,"resets_at":"2026-08-14T05:00:00Z"},
            {"kind":"weekly_notice","group":"weekly","percent":100,"label":"Learn more about usage limits"},
            {
              "kind":"weekly_scoped",
              "group":"weekly",
              "percent":98,
              "resets_at":"2026-08-14T05:00:00Z",
              "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}
            }
          ]
        }
        """

        let quota = try ClaudeOAuthUsageParser.parse(Data(payload.utf8))
        let fable = try #require(quota.fableWindow)

        #expect(quota.primary.usedPercent == 7)
        #expect(quota.secondary?.usedPercent == 57)
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
        #expect(fable.window.usedPercent == 98)
        #expect(fable.window.resetsAt == quota.secondary?.resetsAt)
    }

    @Test("CLI scoped quota supplements API values without replacing them")
    func mergesCLIScopedQuotaIntoAPIQuota() throws {
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8),
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x"
        )
        let fable = ScopedQuotaWindow(
            scopeID: "fable",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 67, windowMinutes: 10_080, resetsAt: nil)
        )

        let merged = api.mergingScopedWindows([fable])

        #expect(merged.primary.usedPercent == 12)
        #expect(merged.secondary?.usedPercent == 34)
        #expect(merged.planName == "Max 20x")
        #expect(merged.fableWindow?.window.usedPercent == 67)
    }

    @Test("A general refresh retains the active Fable quota")
    func retainsActiveFableAcrossGeneralRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-300),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 67,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(3_600)
                    ),
                    observedAt: now.addingTimeInterval(-300)
                )
            ]
        )

        let retained = api.retainingActiveScopedWindows(from: previous, now: now)

        #expect(retained.fableWindow?.window.usedPercent == 67)
    }

    @Test("A reset further out than its own window cannot keep a window alive")
    func dropsScopedWindowWithImplausibleReset() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-300),
            // 一次残缺的 /usage 重绘会把 Fable 的重置解析成一年之后。旧的
            // `resetsAt > now` 判据对这种值永远成立,坏卡片能活满整个周期。
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 98,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(364 * 86_400)
                    ),
                    observedAt: now.addingTimeInterval(-300)
                )
            ]
        )

        #expect(api.retainingActiveScopedWindows(from: previous, now: now).fableWindow == nil)
    }

    @Test("A scoped window from an older build is dropped rather than kept forever")
    func dropsScopedWindowWithoutObservationTimestamp() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-300),
            // 旧版本写下的快照没有 observedAt。此前它靠 previous.capturedAt 判新鲜,
            // 而那个时间戳每轮刷新都会被重写,于是这种窗口永远不过期。
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 67,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(3_600)
                    )
                )
            ]
        )

        #expect(api.retainingActiveScopedWindows(from: previous, now: now).fableWindow == nil)
    }

    @Test("A snapshot that reports its own scoped windows never resurrects older ones")
    func doesNotResurrectWhenCurrentSnapshotHasScopedWindows() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"""
            {"five_hour":{"utilization":12},"seven_day":{"utilization":34},
             "seven_day_fable":{"utilization":98}}
            """#.utf8),
            now: now
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-60),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable_stale_copy",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 0,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(8 * 3_600)
                    ),
                    observedAt: now.addingTimeInterval(-60)
                )
            ]
        )

        let retained = api.retainingActiveScopedWindows(from: previous, now: now)

        // 本轮已经报了自己的 scoped 集合,缺席的就是真的没了,不该被复活成
        // 第二张"100% remaining"的 Fable 卡片。
        #expect(retained.uniqueScopedWindows.map(\.scopeID) == ["fable"])
        #expect(retained.fableWindow?.window.usedPercent == 98)
    }

    @Test("A screen fragment mistaken for a model name is rejected")
    func rejectsCorruptScopedWindowFromOlderParser() {
        // 真实缓存里捞到的化石:旧解析器把进度条和重置行吞进了 displayName,
        // usedPercent 为 0,于是弹窗在真实 Fable(98% used)旁边多画了一张
        // "100% remaining" 的卡片。修好解析器救不了已经存了这条记录的用户。
        let fossil = ScopedQuotaWindow(
            scopeID: "fable_40_used_resets_aug14_at_12",
            displayName: "Fable\n████████████████████    40%used\nResets Aug14 at 12:59pm(Asia/Shanghai",
            window: QuotaWindow(usedPercent: 0, windowMinutes: 10_080, resetsAt: nil)
        )
        let healthy = ScopedQuotaWindow(
            scopeID: "fable",
            displayName: "Fable",
            window: QuotaWindow(usedPercent: 98, windowMinutes: 10_080, resetsAt: nil)
        )

        #expect(!fossil.isPlausibleModelScope)
        #expect(healthy.isPlausibleModelScope)

        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 11, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [healthy, fossil]
        )

        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["fable"])
    }

    @Test("An expired Fable quota is not retained")
    func dropsExpiredFableAcrossGeneralRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-300),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 67,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(-1)
                    )
                )
            ]
        )

        let retained = api.retainingActiveScopedWindows(from: previous, now: now)

        #expect(retained.fableWindow == nil)
    }

    @Test("A stale Fable snapshot is dropped even when its reset remains in the future")
    func dropsStaleFableWithFutureReset() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let api = try ClaudeOAuthUsageParser.parse(
            Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8),
            now: now
        )
        let previous = ProviderQuota(
            provider: .claude,
            primary: api.primary,
            secondary: api.secondary,
            planName: api.planName,
            capturedAt: now.addingTimeInterval(-901),
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(
                        usedPercent: 0,
                        windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(8 * 3_600 + 31 * 60)
                    ),
                    observedAt: now.addingTimeInterval(-901)
                )
            ]
        )

        let retained = api.retainingActiveScopedWindows(from: previous, now: now)

        #expect(retained.fableWindow == nil)
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

    @Test("An isolated managed account never inherits the system Claude credential")
    func managedAccountDoesNotFallBack() {
        let keychainConsulted = ClaudeLockedValue(false)
        var reader = ClaudeCredentialsReader()
        reader.environment = [
            "CLAUDE_CONFIG_DIR": FileManager.default.temporaryDirectory
                .appendingPathComponent("usagedock-managed-missing-\(UUID().uuidString)")
                .path
        ]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-system-home-\(UUID().uuidString)")
        reader.fallbackToDefaultDirectory = false
        reader.allowsKeychain = false
        reader.keychainPayload = { _ in
            keychainConsulted.set(true)
            return KeychainRead.Outcome(
                payload: #"{"claudeAiOauth": {"accessToken": "system-token"}}"#,
                status: errSecSuccess
            )
        }

        #expect(reader.load() == nil)
        #expect(keychainConsulted.get() == false)
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

/// Claude Code 的钥匙串条目 partition list 只有 `apple-tool:`,所以本应用无论被
/// 授权多少次都读不到它 —— 实测那条条目已经信任了四代本应用,依旧每次拒绝。
/// 这条委托路径决定了限额走 API 直查还是 20 秒的 PTY 抓屏,它的边界必须钉住:
/// 直查已经成功、条目根本不存在、以及托管账户,三种情况都不该动用委托。
@Suite("Claude credentials Apple tool delegate")
struct ClaudeAppleToolDelegateTests {
    private static let usablePayload = """
    {"claudeAiOauth": {"accessToken": "sk-ant-oat01-delegated", \
    "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"}}
    """

    private func reader(
        keychain: KeychainRead.Outcome,
        delegate: KeychainRead.Outcome,
        delegateConsulted: ClaudeLockedValue<Bool>
    ) -> ClaudeCredentialsReader {
        var reader = ClaudeCredentialsReader()
        reader.environment = [:]
        reader.homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-missing-\(UUID().uuidString)", isDirectory: true)
        reader.keychainPayload = { _ in keychain }
        reader.appleToolPayload = { _ in
            delegateConsulted.set(true)
            return delegate
        }
        return reader
    }

    @Test("A partition refusal is retried through the Apple tool instead of degrading")
    func delegatesWhenThePartitionLocksTheAppOut() async {
        let consulted = ClaudeLockedValue(false)
        let reader = reader(
            keychain: KeychainRead.Outcome(payload: nil, status: errSecAuthFailed),
            delegate: KeychainRead.Outcome(payload: Self.usablePayload, status: errSecSuccess),
            delegateConsulted: consulted
        )

        let result = await reader.readAllowingAppleTool()

        #expect(consulted.get())
        #expect(result.credentials?.accessToken == "sk-ant-oat01-delegated")
        // 计划名只有直查路径会写出来,它是"没走抓屏"的凭据。
        #expect(result.credentials?.subscriptionType == "max")
        #expect(result.credentials?.rateLimitTier == "default_claude_max_5x")
        #expect(result.source == .keychain)
    }

    @Test("A direct read that already works never spawns the Apple tool")
    func skipsDelegateWhenDirectReadSucceeds() async {
        let consulted = ClaudeLockedValue(false)
        let reader = reader(
            keychain: KeychainRead.Outcome(payload: Self.usablePayload, status: errSecSuccess),
            delegate: KeychainRead.Outcome(payload: nil, status: errSecItemNotFound),
            delegateConsulted: consulted
        )

        let result = await reader.readAllowingAppleTool()

        #expect(result.credentials != nil)
        #expect(consulted.get() == false)
    }

    @Test("A missing item is not an authorization problem and needs no delegate")
    func skipsDelegateWhenTheItemIsAbsent() async {
        let consulted = ClaudeLockedValue(false)
        let reader = reader(
            keychain: KeychainRead.Outcome(payload: nil, status: errSecItemNotFound),
            delegate: KeychainRead.Outcome(payload: Self.usablePayload, status: errSecSuccess),
            delegateConsulted: consulted
        )

        let result = await reader.readAllowingAppleTool()

        #expect(result.credentials == nil)
        #expect(consulted.get() == false)
    }

    /// 委托读的是全局钥匙串条目,也就是 Claude Code 当前登录的那个账户。托管
    /// 账户一旦走这条路,拿到的就是**别人的**额度,比读不到严重得多。
    @Test("An isolated managed account never delegates to the shared keychain item")
    func skipsDelegateForManagedProfiles() async {
        let consulted = ClaudeLockedValue(false)
        var reader = reader(
            keychain: KeychainRead.Outcome(payload: nil, status: errSecAuthFailed),
            delegate: KeychainRead.Outcome(payload: Self.usablePayload, status: errSecSuccess),
            delegateConsulted: consulted
        )
        reader.fallbackToDefaultDirectory = false
        reader.allowsKeychain = false

        let result = await reader.readAllowingAppleTool()

        #expect(result.credentials == nil)
        #expect(consulted.get() == false)
    }

    @Test("An expired delegated token is reported as expired, not as usable")
    func reportsExpiredDelegatedToken() async {
        let expired = Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1000
        let payload = """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat01-stale", "expiresAt": \(Int(expired))}}
        """
        let consulted = ClaudeLockedValue(false)
        let reader = reader(
            keychain: KeychainRead.Outcome(payload: nil, status: errSecAuthFailed),
            delegate: KeychainRead.Outcome(payload: payload, status: errSecSuccess),
            delegateConsulted: consulted
        )

        let result = await reader.readAllowingAppleTool()

        #expect(consulted.get())
        #expect(result.credentials == nil)
        #expect(result.hasExpiredCredentials)
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
