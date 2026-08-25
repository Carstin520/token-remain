import CryptoKit
import Foundation
import Testing
@testable import UsageDock

@Suite("ZCode local credential discovery")
struct ZCodeCredentialReaderTests {
    // MARK: 夹具

    /// 造一个假的用户主目录:`<home>/.zcode/v2/...`。
    private func makeHome(files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "zcode-reader-\(UUID().uuidString)")
        let v2 = home.appending(path: ".zcode/v2")
        try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: v2.appending(path: name))
        }
        return home
    }

    private func reader(
        home: URL,
        environment: [String: String] = [:],
        username: String = "tester"
    ) -> ZCodeCredentialReader {
        ZCodeCredentialReader(
            homeDirectory: home,
            environment: environment,
            username: username,
            platform: "darwin"
        )
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 与 ZCode/TokenTracker 同构的 enc:v1 密文:key = SHA-256(secret),
    /// AES-256-GCM,`enc:v1:<iv>.<tag>.<ciphertext>`(base64url)。
    private func encrypted(_ plaintext: String, secret: String) throws -> String {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        return "enc:v1:\(base64URL(Data(box.nonce))).\(base64URL(box.tag)).\(base64URL(box.ciphertext))"
    }

    private func fallbackSecret(home: URL, username: String = "tester") -> String {
        "zcode-credential-fallback:darwin:\(home.path):\(username)"
    }

    // MARK: enc:v1 解密

    @Test("enc:v1 values decrypt with the platform-derived fallback secret")
    func decryptRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "zc-\(UUID().uuidString)")
        let secret = fallbackSecret(home: home)
        let value = try encrypted("jwt-token-plain", secret: secret)
        let files = ["credentials.json": #"{"zcodejwttoken": "\#(value)"}"#]
        let homeDir = try makeHomeAt(home, files: files)
        #expect(reader(home: homeDir).credentialValue("zcodejwttoken") == "jwt-token-plain")
    }

    private func makeHomeAt(_ home: URL, files: [String: String]) throws -> URL {
        let v2 = home.appending(path: ".zcode/v2")
        try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: v2.appending(path: name))
        }
        return home
    }

    @Test("ZCODE_CREDENTIAL_SECRET overrides the derived secret")
    func decryptWithEnvSecret() throws {
        let value = try encrypted("env-secret-token", secret: "custom-secret")
        let home = try makeHome(files: ["credentials.json": #"{"zcodejwttoken": "\#(value)"}"#])
        let found = reader(
            home: home,
            environment: ["ZCODE_CREDENTIAL_SECRET": "custom-secret"]
        ).credentialValue("zcodejwttoken")
        #expect(found == "env-secret-token")
    }

    @Test("Plaintext passes through; malformed or wrong-key ciphertext yields nil")
    func decryptEdgeCases() throws {
        #expect(ZCodeCredentialReader.decrypt("plain-value", secret: "s") == "plain-value")
        #expect(ZCodeCredentialReader.decrypt("enc:v1:only.two", secret: "s") == nil)
        #expect(ZCodeCredentialReader.decrypt("enc:v1:%%%.$$$.@@@", secret: "s") == nil)
        let sealed = try encrypted("data", secret: "right-secret")
        #expect(ZCodeCredentialReader.decrypt(sealed, secret: "wrong-secret") == nil)
        #expect(ZCodeCredentialReader.decrypt(sealed, secret: "right-secret") == "data")
    }

    // MARK: 候选发现

    @Test("Provider keys map onto plan kind and jurisdiction")
    func providerKeyParsing() {
        #expect(ZCodeCredentialReader.plan(forProviderKey: "builtin:zai-coding-plan")! == (.coding, .zai))
        #expect(ZCodeCredentialReader.plan(forProviderKey: "builtin:bigmodel-start-plan")! == (.start, .bigmodel))
        #expect(ZCodeCredentialReader.plan(forProviderKey: "builtin:zai-start-plan")! == (.start, .zai))
        #expect(ZCodeCredentialReader.plan(forProviderKey: "builtin:bigmodel-coding-plan")! == (.coding, .bigmodel))
        #expect(ZCodeCredentialReader.plan(forProviderKey: "openrouter") == nil)
        #expect(ZCodeCredentialReader.plan(forProviderKey: "builtin:zai-coding-plan-extra") == nil)
    }

    @Test("A configured coding-plan provider becomes a raw-token candidate")
    func codingPlanCandidate() throws {
        let home = try makeHome(files: [
            "config.json": #"""
            {"provider": {"builtin:zai-coding-plan":
                {"options": {"apiKey": "zai-key", "baseURL": "https://api.z.ai/api/anthropic"}}}}
            """#
        ])
        let candidates = reader(home: home).authCandidates()
        #expect(candidates == [ZCodeAuthCandidate(
            providerKey: "builtin:zai-coding-plan",
            planKind: .coding,
            region: .zai,
            token: "zai-key",
            authSource: "provider:config",
            baseURL: "https://api.z.ai/api/anthropic"
        )])
    }

    @Test("setting.json selection reorders candidates ahead of the defaults")
    func selectionOrdering() throws {
        let home = try makeHome(files: [
            "config.json": #"""
            {"provider": {
                "builtin:bigmodel-coding-plan": {"options": {"apiKey": "bm-key"}},
                "builtin:zai-coding-plan": {"options": {"apiKey": "zai-key"}}}}
            """#,
            "setting.json": #"""
            {"providerFamilyDomain": "chat",
             "modelProviderFamilySelectedKeys": {"chat": "builtin:zai-coding-plan@2"}}
            """#
        ])
        let keys = reader(home: home).authCandidates().map(\.providerKey)
        #expect(keys == ["builtin:zai-coding-plan", "builtin:bigmodel-coding-plan"])
    }

    @Test("Cache availability filters out unavailable providers and promotes available ones")
    func availabilityFiltering() throws {
        let home = try makeHome(files: [
            "config.json": #"""
            {"provider": {
                "builtin:bigmodel-coding-plan": {"options": {"apiKey": "bm-key"}},
                "builtin:zai-coding-plan": {"options": {"apiKey": "zai-key"}}}}
            """#,
            "coding-plan-cache.json": #"""
            {"entryStatus": {"items": {
                "builtin:zai-coding-plan": {"status": "available"},
                "builtin:bigmodel-coding-plan": {"status": "unavailable"}}}}
            """#
        ])
        let candidates = reader(home: home).authCandidates()
        #expect(candidates.map(\.providerKey) == ["builtin:zai-coding-plan"])
    }

    @Test("Disabled providers and non-plan keys are skipped")
    func disabledProviderSkipped() throws {
        let home = try makeHome(files: [
            "config.json": #"""
            {"provider": {
                "builtin:zai-coding-plan": {"enabled": false, "options": {"apiKey": "zai-key"}},
                "openrouter": {"options": {"apiKey": "or-key"}}}}
            """#
        ])
        #expect(reader(home: home).authCandidates().isEmpty)
    }

    @Test("The start-plan login token is only used when the active provider matches")
    func startPlanCredentialGating() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "zc-\(UUID().uuidString)")
        let secret = fallbackSecret(home: home)
        let jwt = try encrypted("login-jwt", secret: secret)
        _ = try makeHomeAt(home, files: [
            "config.json": #"""
            {"provider": {
                "builtin:zai-start-plan": {"options": {"apiKey": "start-config-key"}},
                "builtin:bigmodel-start-plan": {"options": {}}}}
            """#,
            "credentials.json": #"""
            {"zcodejwttoken": "\#(jwt)", "oauth:active_provider": "zai"}
            """#
        ])
        let candidates = reader(home: home).authCandidates()
        // bigmodel-start 在默认序前面,但 active_provider=zai,它拿不到登录
        // 态、又没有配置 Key,所以只剩 zai-start 的两条来源。
        #expect(candidates.map(\.token) == ["login-jwt", "start-config-key"])
        #expect(candidates.map(\.authSource) == ["credential:zcodejwttoken", "provider:config"])
        #expect(candidates.allSatisfy { $0.providerKey == "builtin:zai-start-plan" })
    }

    @Test("Missing config or malformed JSON yields no candidates")
    func malformedConfig() throws {
        #expect(reader(home: try makeHome(files: [:])).authCandidates().isEmpty)
        #expect(reader(home: try makeHome(files: ["config.json": "not json"])).authCandidates().isEmpty)
        #expect(reader(home: try makeHome(files: ["config.json": #"{"provider": 5}"#])).authCandidates().isEmpty)
    }

    // MARK: 请求契约

    private func candidate(
        _ key: String,
        token: String = "tok",
        baseURL: String? = nil
    ) -> ZCodeAuthCandidate {
        let (kind, region) = ZCodeCredentialReader.plan(forProviderKey: key)!
        return ZCodeAuthCandidate(
            providerKey: key, planKind: kind, region: region,
            token: token, authSource: "provider:config", baseURL: baseURL
        )
    }

    @Test("Coding-plan requests use the jurisdiction host and a raw token")
    func codingPlanContract() {
        let zai = ZCodeQuotaContract.request(
            for: candidate("builtin:zai-coding-plan", token: "raw-token"),
            appVersion: "3.2.5"
        )
        #expect(zai.url.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(zai.headers["Authorization"] == "raw-token")

        let bigmodel = ZCodeQuotaContract.request(
            for: candidate("builtin:bigmodel-coding-plan", token: "raw-token"),
            appVersion: "3.2.5"
        )
        #expect(bigmodel.url.absoluteString == "https://bigmodel.cn/api/monitor/usage/quota/limit")
        #expect(bigmodel.headers["Authorization"] == "raw-token")
    }

    @Test("A configured baseURL only overrides the monitor host inside api.z.ai")
    func codingPlanBaseURLBoundary() {
        let allowed = ZCodeQuotaContract.request(
            for: candidate("builtin:zai-coding-plan", baseURL: "https://cn.api.z.ai/api/anthropic"),
            appVersion: "1"
        )
        #expect(allowed.url.absoluteString == "https://cn.api.z.ai/api/monitor/usage/quota/limit")

        for hostile in [
            "https://evil.example.com/api",
            "https://api.z.ai.evil.example.com/api",
            "http://api.z.ai/api"
        ] {
            let request = ZCodeQuotaContract.request(
                for: candidate("builtin:zai-coding-plan", baseURL: hostile),
                appVersion: "1"
            )
            #expect(
                request.url.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit",
                "\(hostile) must not override the jurisdiction host"
            )
        }
    }

    @Test("Start-plan requests use the billing endpoint with Bearer and ZCode headers")
    func startPlanContract() {
        let request = ZCodeQuotaContract.request(
            for: candidate("builtin:zai-start-plan", token: "login-jwt"),
            appVersion: "9.9.9",
            deviceMid: "mid-42"
        )
        #expect(request.url.host() == "zcode.z.ai")
        #expect(request.url.path() == "/api/v1/zcode-plan/billing/balance")
        #expect(request.url.query() == "app_version=9.9.9")
        #expect(request.headers["Authorization"] == "Bearer login-jwt")
        #expect(request.headers["User-Agent"] == "ZCode/9.9.9")
        #expect(request.headers["X-ZCode-App-Version"] == "9.9.9")
        #expect(request.headers["X-Platform"] == "darwin")
        #expect(request.headers["X-Device-Mid"] == "mid-42")
        let withoutMid = ZCodeQuotaContract.request(
            for: candidate("builtin:bigmodel-start-plan", token: "t"),
            appVersion: "1.0"
        )
        #expect(withoutMid.headers["X-Device-Mid"] == nil)
        // bigmodel 的 start-plan 登录态同样只发官方计费主机。
        #expect(withoutMid.url.host() == "zcode.z.ai")
    }

    // MARK: start-plan 余额解析

    @Test("The busiest model pool becomes the named primary; the sibling stays scoped")
    func billingParse() throws {
        let payload = #"""
        {"code": 0, "data": {"server_time": 1800000000, "balances": [
            {"show_name": "GLM-5-Turbo", "plan_id": "zcode-v3-pro-plan-0615",
             "total_units": 50, "used_units": 10, "remaining_units": 40,
             "period_end": 1800600000},
            {"show_name": "GLM-5.2", "plan_id": "zcode-v3-pro-plan-0615",
             "total_units": 200, "used_units": 150, "remaining_units": 50,
             "period_end": 1800700000}
        ]}}
        """#
        let quota = try ZCodeQuotaContract.parseBilling(Data(payload.utf8))
        #expect(quota.provider == .zai)
        // GLM-5.2 用掉 75%,比 GLM-5-Turbo 的 20% 更紧张——它才是主窗口,
        // 哪怕它的池子更大;池名跟着主窗口走。
        #expect(quota.primary.usedPercent == 75)
        #expect(quota.primary.poolName == "GLM-5.2")
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_800_700_000))
        // 上游只给周期终点没有起点,差值是剩余时间而非窗口时长,逐刷会缩水;
        // 时长固定按月度套餐节奏取 43_200 分钟,resetsAt 保留真实 period_end。
        #expect(quota.primary.windowMinutes == 43_200)
        // 兄弟池绝不进 secondary(同时长的账户级双窗会被手机同步整份拒收),
        // 以命名 scoped 窗口保留。
        #expect(quota.secondary == nil)
        let sibling = try #require(quota.scopedWindows?.first)
        #expect(quota.scopedWindows?.count == 1)
        #expect(sibling.scopeID == "zcode_glm_5_turbo")
        #expect(sibling.displayName == "GLM-5-Turbo")
        #expect(sibling.window.usedPercent == 20)
        #expect(sibling.window.windowMinutes == 43_200)
        #expect(sibling.window.resetsAt == Date(timeIntervalSince1970: 1_800_600_000))
        #expect(sibling.observedAt != nil)
        #expect(quota.planName == "ZCode Pro")
    }

    @Test("Three pools all survive; the plan label follows the primary's bucket")
    func billingParseThreePools() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // plan_id 故意错开,验证计划名取的是主窗口所属桶,而不是
        // balances.first。
        let payload = #"""
        {"code": 0, "data": {"balances": [
            {"show_name": "GLM-5-Turbo", "plan_id": "zcode-v3-pro-plan",
             "total_units": 50, "used_units": 10, "period_end": 1800600000},
            {"show_name": "GLM-5.2", "plan_id": "zcode-v3-max-plan",
             "total_units": 200, "used_units": 150, "period_end": 1800700000},
            {"show_name": "GLM-5V", "plan_id": "zcode-v3-pro-plan",
             "total_units": 100, "used_units": 5}
        ]}}
        """#
        let quota = try ZCodeQuotaContract.parseBilling(Data(payload.utf8), now: now)
        #expect(quota.primary.poolName == "GLM-5.2")
        #expect(quota.primary.usedPercent == 75)
        #expect(quota.primary.windowMinutes == 43_200)
        #expect(quota.planName == "ZCode Max")
        #expect(quota.secondary == nil)
        // 第 3 池不再丢弃;兄弟池按用量降序排列。
        let scoped = try #require(quota.scopedWindows)
        #expect(scoped.map(\.scopeID) == ["zcode_glm_5_turbo", "zcode_glm_5v"])
        #expect(scoped.map(\.displayName) == ["GLM-5-Turbo", "GLM-5V"])
        #expect(scoped[0].window.usedPercent == 20)
        #expect(scoped[0].window.windowMinutes == 43_200)
        // 缺 period_end 的池同样固定月窗,resetsAt 保持未知。
        #expect(scoped[1].window.usedPercent == 5)
        #expect(scoped[1].window.windowMinutes == 43_200)
        #expect(scoped[1].window.resetsAt == nil)
        #expect(scoped.allSatisfy { $0.observedAt == now })
    }

    @Test("Empty balances or a business error code are treated as unusable")
    func billingParseFailures() {
        #expect(throws: ZAIUsageService.ServiceError.self) {
            _ = try ZCodeQuotaContract.parseBilling(Data(#"{"code": 0, "data": {"balances": []}}"#.utf8))
        }
        #expect(throws: ZAIUsageService.ServiceError.self) {
            _ = try ZCodeQuotaContract.parseBilling(Data(#"{"code": 1001, "msg": "nope"}"#.utf8))
        }
        #expect(throws: ZAIUsageService.ServiceError.self) {
            _ = try ZCodeQuotaContract.parseBilling(Data("not json".utf8))
        }
        // 全是无效桶(total 为 0)同样视为不可用。
        #expect(throws: ZAIUsageService.ServiceError.self) {
            _ = try ZCodeQuotaContract.parseBilling(
                Data(#"{"data": {"balances": [{"total_units": 0, "used_units": 0}]}}"#.utf8)
            )
        }
    }

    @Test("Plan labels extract the human tier from raw plan ids")
    func planLabels() {
        #expect(ZCodeQuotaContract.planLabel(fromPlanID: "zcode-v3-start-plan-0615") == "Start")
        #expect(ZCodeQuotaContract.planLabel(fromPlanID: "ZCODE-MAX-2024") == "Max")
        #expect(ZCodeQuotaContract.planLabel(fromPlanID: "lite") == "Lite")
        #expect(ZCodeQuotaContract.planLabel(fromPlanID: "zcode-v3-plan") == nil)
        #expect(ZCodeQuotaContract.planLabel(fromPlanID: nil) == nil)
        #expect(ZCodeQuotaContract.codingPlanName(Data(#"{"data": {"level": "pro"}}"#.utf8)) == "ZCode Pro")
        #expect(ZCodeQuotaContract.codingPlanName(Data(#"{"data": {}}"#.utf8)) == nil)
    }
}

@Suite("Z.ai usage service credential priority")
struct ZAIUsageServicePriorityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let quotaBody = Data(#"""
    {"data": {"level": "pro", "limits": [
        {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 30, "nextResetTime": 1800018000000}
    ]}}
    """#.utf8)
    private static let billingBody = Data(#"""
    {"code": 0, "data": {"balances": [
        {"plan_id": "zcode-v3-start-plan-1", "total_units": 100, "used_units": 40,
         "period_end": 1800600000}
    ]}}
    """#.utf8)

    private final class HTTPRecorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        let responder: (URLRequest) -> (Data, Int)
        init(_ responder: @escaping (URLRequest) -> (Data, Int)) { self.responder = responder }

        func perform(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            requests.append(request)
            let (data, status) = responder(request)
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!)
        }
    }

    private func candidate(_ key: String, token: String) -> ZCodeAuthCandidate {
        let (kind, region) = ZCodeCredentialReader.plan(forProviderKey: key)!
        return ZCodeAuthCandidate(
            providerKey: key, planKind: kind, region: region,
            token: token, authSource: "provider:config", baseURL: nil
        )
    }

    private func makeService(
        candidates: [ZCodeAuthCandidate],
        manual: String?,
        region: ZAIAPIRegion = .global,
        recorder: HTTPRecorder
    ) -> ZAIUsageService {
        ZAIUsageService(
            region: region,
            loadLocalCandidates: { candidates },
            loadManualKey: { manual },
            loadStartPlanDeviceMid: { "mid-test" },
            zcodeAppVersion: { "3.2.5" },
            perform: { recorder.perform($0) }
        )
    }

    @Test("A routed key with its explicit region wins over local discovery")
    func routedKeyFirst() async throws {
        let recorder = HTTPRecorder { request in
            request.url!.path().contains("quota") ? (Self.quotaBody, 200) : (Data(), 500)
        }
        let service = ZAIUsageService(
            region: .global,
            loadLocalCandidates: {
                Issue.record("local discovery must not run for a routed key")
                return []
            },
            loadManualKey: { nil },
            loadStartPlanDeviceMid: { nil },
            zcodeAppVersion: { "1" },
            perform: { recorder.perform($0) }
        )
        _ = try await service.fetch(apiKey: "routed-key", region: .china, now: now)
        #expect(recorder.requests.first?.url?.host() == "open.bigmodel.cn")
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer routed-key")
    }

    @Test("A ZCode coding-plan candidate is served from its own jurisdiction host")
    func localCodingCandidate() async throws {
        let recorder = HTTPRecorder { _ in (Self.quotaBody, 200) }
        let service = makeService(
            candidates: [candidate("builtin:zai-coding-plan", token: "zcode-raw")],
            manual: "manual-key",
            recorder: recorder
        )
        let quota = try await service.fetch(now: now)
        #expect(quota.provider == .zai)
        #expect(quota.planName == "ZCode Pro")
        #expect(quota.primary.usedPercent == 30)
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].url?.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "zcode-raw")
    }

    @Test("A ZCode start-plan candidate uses the billing contract")
    func localStartCandidate() async throws {
        let recorder = HTTPRecorder { _ in (Self.billingBody, 200) }
        let service = makeService(
            candidates: [candidate("builtin:zai-start-plan", token: "login-jwt")],
            manual: nil,
            recorder: recorder
        )
        let quota = try await service.fetch(now: now)
        #expect(quota.planName == "ZCode Start")
        #expect(quota.primary.usedPercent == 40)
        let request = recorder.requests[0]
        #expect(request.url?.host() == "zcode.z.ai")
        #expect(request.url?.query()?.contains("app_version=3.2.5") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer login-jwt")
        #expect(request.value(forHTTPHeaderField: "X-Device-Mid") == "mid-test")
    }

    @Test("Unusable local candidates fall back to the manual key and its explicit region")
    func localFailureFallsBackToManual() async throws {
        let recorder = HTTPRecorder { request in
            if request.value(forHTTPHeaderField: "Authorization") == "dead-token" {
                return (Data(), 401)
            }
            if request.url!.path().contains("subscription") { return (Data(), 500) }
            return (Self.quotaBody, 200)
        }
        let service = makeService(
            candidates: [candidate("builtin:zai-coding-plan", token: "dead-token")],
            manual: "manual-key",
            region: .china,
            recorder: recorder
        )
        let quota = try await service.fetch(now: now)
        #expect(quota.provider == .zai)
        // 手动 Key 按用户显式区域走国内主机,绝不复用候选的辖区。
        let manualRequest = recorder.requests.first {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer manual-key"
        }
        #expect(manualRequest?.url?.host() == "open.bigmodel.cn")
    }

    @Test("A no-coding-plan response moves on to the next candidate")
    func noCodingPlanTriesNextCandidate() async throws {
        let noPlan = Data(#"{"success": false, "msg": "no coding plan"}"#.utf8)
        let recorder = HTTPRecorder { request in
            request.url!.host() == "zcode.z.ai" ? (Self.billingBody, 200) : (noPlan, 200)
        }
        let service = makeService(
            candidates: [
                candidate("builtin:zai-coding-plan", token: "coding-token"),
                candidate("builtin:zai-start-plan", token: "start-token")
            ],
            manual: nil,
            recorder: recorder
        )
        let quota = try await service.fetch(now: now)
        #expect(quota.planName == "ZCode Start")
        #expect(recorder.requests.count == 2)
    }

    @Test("Failed candidates without a manual key surface the local error")
    func localFailureWithoutManual() async {
        let recorder = HTTPRecorder { _ in (Data(), 401) }
        let service = makeService(
            candidates: [candidate("builtin:zai-coding-plan", token: "t")],
            manual: nil,
            recorder: recorder
        )
        await #expect(throws: ZAIUsageService.ServiceError.self) {
            _ = try await service.fetch(now: now)
        }
    }

    @Test("Nothing configured surfaces missingKey without any request")
    func nothingConfigured() async {
        let recorder = HTTPRecorder { _ in (Data(), 200) }
        let service = makeService(candidates: [], manual: nil, recorder: recorder)
        await #expect(throws: ZAIUsageService.ServiceError.self) {
            _ = try await service.fetch(now: now)
        }
        #expect(recorder.requests.isEmpty)
    }
}
