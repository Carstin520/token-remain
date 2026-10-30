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

    @Test("Splits the two pools, promoting the busier one to the primary bar")
    func splitsPoolsWithBusierPrimary() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let end = 1_784_592_000_000.0
        let payload = """
        {
          "enabled": true,
          "planUsage": {
            "autoPercentUsed": 1.93,
            "apiPercentUsed": 91.07,
            "totalPercentUsed": 12.7
          },
          "billingCycleStart": 1782000000000,
          "billingCycleEnd": \(end)
        }
        """
        let quota = try CursorAPIUsageParser.parse(Data(payload.utf8), planName: "pro", now: now)

        #expect(quota.primary.usedPercent == 91.07)
        #expect(quota.primary.poolName == CursorAPIUsageParser.apiPoolName)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: end / 1000))
        #expect(quota.secondary == nil)

        let scoped = try #require(quota.uniqueScopedWindows.first)
        #expect(quota.uniqueScopedWindows.count == 1)
        #expect(scoped.scopeID == CursorAPIUsageParser.autoPoolScopeID)
        #expect(scoped.displayName == CursorAPIUsageParser.autoPoolName)
        #expect(scoped.window.usedPercent == 1.93)
        #expect(scoped.window.windowMinutes == quota.primary.windowMinutes)
        #expect(scoped.window.resetsAt == quota.primary.resetsAt)
        #expect(scoped.observedAt == now)
    }

    @Test("The Cursor pool leads when it is the busier one, and ties favor it")
    func autoPoolLeadsWhenBusierOrTied() throws {
        let busier = """
        {"enabled": true, "planUsage": {"autoPercentUsed": 70, "apiPercentUsed": 30}}
        """
        let busierQuota = try CursorAPIUsageParser.parse(Data(busier.utf8))
        #expect(busierQuota.primary.usedPercent == 70)
        #expect(busierQuota.primary.poolName == CursorAPIUsageParser.autoPoolName)
        #expect(busierQuota.uniqueScopedWindows.first?.scopeID == CursorAPIUsageParser.apiPoolScopeID)

        let tied = """
        {"enabled": true, "planUsage": {"autoPercentUsed": 40, "apiPercentUsed": 40}}
        """
        let tiedQuota = try CursorAPIUsageParser.parse(Data(tied.utf8))
        #expect(tiedQuota.primary.poolName == CursorAPIUsageParser.autoPoolName)
    }

    @Test("Pool percentages are clamped into 0...100")
    func clampsPoolPercents() throws {
        let payload = """
        {"enabled": true, "planUsage": {"autoPercentUsed": 130, "apiPercentUsed": -5}}
        """
        let quota = try CursorAPIUsageParser.parse(Data(payload.utf8))
        #expect(quota.primary.usedPercent == 100)
        #expect(quota.uniqueScopedWindows.first?.window.usedPercent == 0)
    }

    @Test("A lone pool percentage becomes the named primary instead of the blended bar")
    func lonePoolStaysNamed() throws {
        // 只剩一个池字段时不再退回混合 totalPercentUsed(那会重新掩盖
        // 先耗尽的池):该命名池直接做主窗口,无 scoped 兄弟。
        let autoOnly = """
        {"enabled": true, "planUsage": {"autoPercentUsed": 30, "totalPercentUsed": 12}}
        """
        let autoQuota = try CursorAPIUsageParser.parse(Data(autoOnly.utf8))
        #expect(autoQuota.primary.usedPercent == 30)
        #expect(autoQuota.primary.poolName == CursorAPIUsageParser.autoPoolName)
        #expect(autoQuota.scopedWindows == nil)

        let apiOnly = """
        {"enabled": true, "planUsage": {"apiPercentUsed": 55, "totalPercentUsed": 12}}
        """
        let apiQuota = try CursorAPIUsageParser.parse(Data(apiOnly.utf8))
        #expect(apiQuota.primary.usedPercent == 55)
        #expect(apiQuota.primary.poolName == CursorAPIUsageParser.apiPoolName)
        #expect(apiQuota.scopedWindows == nil)

        // 两个池字段都缺才轮到混合值兜底。
        let blended = """
        {"enabled": true, "planUsage": {"totalPercentUsed": 12}}
        """
        let blendedQuota = try CursorAPIUsageParser.parse(Data(blended.utf8))
        #expect(blendedQuota.primary.usedPercent == 12)
        #expect(blendedQuota.primary.poolName == nil)
        #expect(blendedQuota.scopedWindows == nil)
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

@Suite("Cursor model usage parser")
struct CursorModelUsageParserTests {
    @Test("Request body carries the billing cycle as Connect int64 strings")
    func buildsCycleRequest() throws {
        let usage = Data(#"{"billingCycleStart":"1790000000000","billingCycleEnd":1792592000000,"planUsage":{}}"#.utf8)
        let body = try #require(CursorModelUsageParser.requestBody(fromCurrentPeriodUsage: usage))
        #expect(String(decoding: body, as: UTF8.self)
            == #"{"endDate":"1792592000000","startDate":"1790000000000"}"#)

        #expect(CursorModelUsageParser.requestBody(fromCurrentPeriodUsage: Data(#"{"planUsage":{}}"#.utf8)) == nil)
        #expect(CursorModelUsageParser.requestBody(
            fromCurrentPeriodUsage: Data(#"{"billingCycleStart":"5","billingCycleEnd":"5"}"#.utf8)
        ) == nil)
    }

    @Test("Aggregations become per-model rows sorted by total tokens")
    func parsesAggregations() throws {
        let payload = """
        {
          "aggregations": [
            {"modelIntent": "gpt-5.5", "inputTokens": "1200", "outputTokens": "300", "cacheReadTokens": "500", "totalCents": 12.5},
            {"modelIntent": "claude-4.6-sonnet-thinking", "inputTokens": "40000", "outputTokens": "2000",
             "cacheWriteTokens": "1000", "cacheReadTokens": "900000", "totalCents": 230.75},
            {"modelIntent": "auto", "input_tokens": 50, "output_tokens": 10},
            {"modelIntent": "  ", "inputTokens": "999999"},
            {"modelIntent": "unused", "inputTokens": "0", "totalCents": 0}
          ],
          "totalInputTokens": "41250"
        }
        """
        let models = try #require(CursorModelUsageParser.parse(Data(payload.utf8)))
        #expect(models.map(\.model) == ["claude-4.6-sonnet-thinking", "gpt-5.5", "auto"])
        #expect(models[0].totalTokens == 943_000)
        #expect(models[0].costCents == 230.75)
        #expect(models[1].totalTokens == 2_000)
        // snake_case 与数字形态的 int64 同样接受;缺费用时为 nil。
        #expect(models[2].totalTokens == 60)
        #expect(models[2].costCents == nil)
    }

    @Test("Missing aggregations yield nil rather than an empty breakdown")
    func rejectsUnexpectedShapes() {
        #expect(CursorModelUsageParser.parse(Data("[]".utf8)) == nil)
        #expect(CursorModelUsageParser.parse(Data(#"{"totalInputTokens":"1"}"#.utf8)) == nil)
        #expect(CursorModelUsageParser.parse(Data(#"{"aggregations":[]}"#.utf8)) == [])
    }

    @Test("Model breakdown survives the cache round-trip and old caches still decode")
    func cacheCompatibility() throws {
        var quota = ProviderQuota(
            provider: .cursor,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 43_200, resetsAt: nil),
            secondary: nil,
            planName: "Pro",
            capturedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        quota.modelUsage = [ProviderModelUsage(
            model: "gpt-5.5", inputTokens: 1, outputTokens: 2,
            cacheWriteTokens: 3, cacheReadTokens: 4, costCents: nil
        )]
        let decoded = try JSONDecoder().decode(ProviderQuota.self, from: JSONEncoder().encode(quota))
        #expect(decoded.modelUsage == quota.modelUsage)

        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(quota)) as? [String: Any]
        )
        legacy.removeValue(forKey: "modelUsage")
        let old = try JSONDecoder().decode(
            ProviderQuota.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(old.modelUsage == nil)
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

    private static let now = Date(timeIntervalSince1970: 1_784_000_000)

    /// Unsigned fixture JWT; the reader only decodes `sub` / `exp`.
    private static func fixtureJWT(sub: String, exp: Date) -> String {
        let payload = #"{"sub":"\#(sub)","exp":\#(Int(exp.timeIntervalSince1970))}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded).fixture"
    }

    private static func stateDB(accessToken: String) async throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-cursor-\(UUID().uuidString).vscdb").path
        _ = try await ProcessRunner.run("/usr/bin/sqlite3", arguments: [
            path,
            """
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(accessToken)');
            """
        ])
        return path
    }

    @Test("An expired IDE token yields to a fresh cursor-agent token for the same account")
    func expiredStateTokenUsesSameAccountKeychainToken() async throws {
        let expired = Self.fixtureJWT(sub: "auth0|user-a", exp: Self.now.addingTimeInterval(-60))
        let fresh = Self.fixtureJWT(sub: "auth0|user-a", exp: Self.now.addingTimeInterval(3_600))
        let path = try await Self.stateDB(accessToken: expired)
        defer { try? FileManager.default.removeItem(atPath: path) }

        var reader = CursorAuthReader()
        reader.stateDBURL = URL(fileURLWithPath: path)
        reader.keychainPayload = { fresh }
        let auth = await reader.load(now: Self.now)
        #expect(auth?.accessToken == fresh)
    }

    @Test("A cursor-agent token for another account never replaces the IDE login")
    func expiredStateTokenIgnoresOtherAccountKeychainToken() async throws {
        let expired = Self.fixtureJWT(sub: "auth0|user-a", exp: Self.now.addingTimeInterval(-60))
        let otherAccount = Self.fixtureJWT(sub: "auth0|user-b", exp: Self.now.addingTimeInterval(3_600))
        let path = try await Self.stateDB(accessToken: expired)
        defer { try? FileManager.default.removeItem(atPath: path) }

        var reader = CursorAuthReader()
        reader.stateDBURL = URL(fileURLWithPath: path)
        reader.keychainPayload = { otherAccount }
        let auth = await reader.load(now: Self.now)
        // The expired IDE token comes back so the service reports staleLogin.
        #expect(auth?.accessToken == expired)
    }

    @Test("An expired IDE token is still returned when no fresher token exists")
    func expiredStateTokenWithoutAlternative() async throws {
        let expired = Self.fixtureJWT(sub: "auth0|user-a", exp: Self.now.addingTimeInterval(-60))
        let staleCLI = Self.fixtureJWT(sub: "auth0|user-a", exp: Self.now.addingTimeInterval(-120))
        let path = try await Self.stateDB(accessToken: expired)
        defer { try? FileManager.default.removeItem(atPath: path) }

        var reader = CursorAuthReader()
        reader.stateDBURL = URL(fileURLWithPath: path)
        reader.keychainPayload = { staleCLI }
        #expect(await reader.load(now: Self.now)?.accessToken == expired)

        reader.keychainPayload = { nil }
        #expect(await reader.load(now: Self.now)?.accessToken == expired)
    }

    @Test("Accounts match only when both tokens carry the same subject")
    func sameAccountRequiresMatchingSubject() {
        let exp = Self.now
        #expect(CursorAuthReader.sameAccount(
            Self.fixtureJWT(sub: "auth0|a", exp: exp),
            Self.fixtureJWT(sub: "auth0|a", exp: exp)
        ))
        #expect(!CursorAuthReader.sameAccount(
            Self.fixtureJWT(sub: "auth0|a", exp: exp),
            Self.fixtureJWT(sub: "auth0|b", exp: exp)
        ))
        #expect(!CursorAuthReader.sameAccount("opaque-token", Self.fixtureJWT(sub: "auth0|a", exp: exp)))
    }
}

@Suite("Cursor usage HTTP status")
struct CursorUsageStatusTests {
    @Test("Only 401 means an expired login; 403 and others report their status")
    func statusClassification() {
        #expect(CursorUsageService.failure(forStatus: 200) == nil)
        #expect(CursorUsageService.failure(forStatus: 204) == nil)
        guard case .staleLogin? = CursorUsageService.failure(forStatus: 401) else {
            Issue.record("401 must map to staleLogin")
            return
        }
        for status in [403, 429, 500] {
            guard case .requestFailed(let reported)? = CursorUsageService.failure(forStatus: status) else {
                Issue.record("\(status) must map to requestFailed")
                continue
            }
            #expect(reported == status)
        }
    }
}

@Suite("Cursor headline pool")
struct CursorHeadlinePoolTests {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    /// Issue #92: Other Models used up, Cursor Models at 67.9% used.
    private func splitQuota() throws -> ProviderQuota {
        let payload = """
        {"enabled": true, "planUsage": {"autoPercentUsed": 67.9, "apiPercentUsed": 100},
         "billingCycleStart": 1782000000000, "billingCycleEnd": 1784592000000}
        """
        return try CursorAPIUsageParser.parse(Data(payload.utf8), now: now)
    }

    @Test("The busiest default keeps the parsed shape")
    func busiestIsUnchanged() throws {
        let quota = try splitQuota()
        let headlined = CursorAPIUsageParser.headlined(quota, on: .busiest)
        #expect(headlined.primary.poolName == CursorAPIUsageParser.apiPoolName)
        #expect(headlined.primary.usedPercent == 100)
        #expect(CursorAPIUsageParser.headlined(quota, on: .otherModels).primary.usedPercent == 100)
    }

    @Test("Choosing Cursor Models swaps the pools without dropping either")
    func cursorModelsSwapsPools() throws {
        let quota = try splitQuota()
        let headlined = CursorAPIUsageParser.headlined(quota, on: .cursorModels)

        #expect(headlined.primary.poolName == CursorAPIUsageParser.autoPoolName)
        #expect(headlined.primary.usedPercent == 67.9)
        #expect(headlined.primary.resetsAt == quota.primary.resetsAt)
        #expect(headlined.primary.windowMinutes == quota.primary.windowMinutes)
        #expect(headlined.capturedAt == quota.capturedAt)

        let scoped = try #require(headlined.uniqueScopedWindows.first)
        #expect(headlined.uniqueScopedWindows.count == 1)
        #expect(scoped.scopeID == CursorAPIUsageParser.apiPoolScopeID)
        #expect(scoped.displayName == CursorAPIUsageParser.apiPoolName)
        #expect(scoped.window.usedPercent == 100)
        #expect(scoped.window.poolName == nil)
        #expect(scoped.observedAt == now)

        let summary = headlined.generalQuotaSummary(strategy: .lowestRemaining)
        #expect(abs(summary.remainingPercent - 32.1) < 0.0001)
        #expect(StatusBarPresentation.remainingText(for: headlined) == UsageFormatting.percent(100 - 67.9))
        #expect(StatusBarPresentation.remainingText(for: quota) == UsageFormatting.percent(0))
    }

    @Test("A missing pool, a blended bar, or another provider stays untouched")
    func unavailablePoolsAreUnchanged() throws {
        let lone = try CursorAPIUsageParser.parse(Data("""
        {"enabled": true, "planUsage": {"apiPercentUsed": 100}}
        """.utf8), now: now)
        #expect(CursorAPIUsageParser.headlined(lone, on: .cursorModels).primary.usedPercent == 100)

        let blended = try CursorAPIUsageParser.parse(Data("""
        {"enabled": true, "planUsage": {"totalPercentUsed": 40}}
        """.utf8), now: now)
        #expect(CursorAPIUsageParser.headlined(blended, on: .cursorModels).primary.usedPercent == 40)

        let other = ProviderQuota(
            provider: .copilot,
            primary: QuotaWindow(usedPercent: 90, windowMinutes: 43_200, resetsAt: nil, poolName: "Premium"),
            secondary: nil,
            planName: nil,
            capturedAt: now
        )
        #expect(UsageStore.headlined(other, cursorPool: .cursorModels).primary.usedPercent == 90)
        #expect(UsageStore.headlined(try splitQuota(), cursorPool: .cursorModels).primary.usedPercent == 67.9)
    }
}

@Suite("Cursor optional model request deadline")
struct CursorModelRequestDeadlineTests {
    @Test("A stalled optional request times out and cancels its transport")
    func timeoutCancelsTransport() async {
        let state = CancellationState()
        let start = ContinuousClock.now
        let result = await CursorUsageService.fetchModelUsage(
            accessToken: "fixture", body: Data(), timeout: 0.03
        ) { _ in
            do { try await Task.sleep(for: .seconds(60)) }
            catch { await state.cancelled(); throw error }
            throw URLError(.unknown)
        }
        #expect(result == nil)
        #expect(start.duration(to: .now) < .seconds(1))
        for _ in 0..<100 {
            if await state.value { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await state.value)
    }

    @Test("Cancelling an optional request cancels the underlying transport")
    func cancellation() async {
        let state = CancellationState()
        let task = Task {
            await CursorUsageService.fetchModelUsage(accessToken: "fixture", body: Data()) { _ in
                await state.started()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { await state.cancelled(); throw error }
                throw URLError(.unknown)
            }
        }
        for _ in 0..<100 {
            if await state.didStart { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await state.didStart)
        task.cancel()
        #expect(await task.value == nil)
        for _ in 0..<100 {
            if await state.value { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await state.value)
    }

    private actor CancellationState {
        var value = false
        var didStart = false
        func cancelled() { value = true }
        func started() { didStart = true }
    }
}
