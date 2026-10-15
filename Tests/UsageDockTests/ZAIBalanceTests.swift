import Foundation
import Testing
@testable import UsageDock

private let balanceFixture = Data(#"{"success":true,"data":{"availableBalance":"123.45","rechargeAmount":500,"totalSpendAmount":300,"frozenBalance":76.55}}"#.utf8)
private let balanceNow = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("BigModel API balance parser")
struct ZAIBalanceParserTests {
    @Test("Only availableBalance becomes a CNY amount; no invented spend ratio")
    func availableBalance() throws {
        let quota = try ZAIBalanceParser.parse(balanceFixture, now: balanceNow)
        #expect(quota.provider == .zai)
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 123.45, currencyCode: "CNY"))
        #expect(quota.remainingBalance == quota.primary.remainingBalance)
        #expect(quota.generalQuotaSummary.remainingBalance?.displayText == "¥123.45")
        #expect(QuotaWindowRow.remainingValueText(remainingPercent: 100, remainingBalance: quota.remainingBalance) == "¥123.45")
        #expect(quota.primary.windowMinutes == 0)
        #expect(quota.primary.usedPercent == 0)
        #expect(quota.primary.resetsAt == nil)
        #expect(quota.secondary == nil)
        #expect(quota.scopedWindows == nil)
        #expect(quota.extraUsage == nil)
        #expect(quota.spend == nil)
        #expect(quota.capturedAt == balanceNow)
    }

    @Test("Numeric zero is a successful, empty wallet")
    func zero() throws {
        let quota = try ZAIBalanceParser.parse(Data(#"{"success":true,"data":{"availableBalance":0}}"#.utf8))
        #expect(quota.remainingBalance?.amount == 0)
        #expect(quota.remainingBalance?.displayText == "¥0.00")
        #expect(quota.primary.usedPercent == 100)
    }

    @Test("Accepts JSON numbers without rounding away the original amount")
    func numericAmount() throws {
        let quota = try ZAIBalanceParser.parse(Data(#"{"success":true,"data":{"availableBalance":1.23456}}"#.utf8))
        #expect(quota.remainingBalance?.amount == 1.23456)
        #expect(quota.remainingBalance?.displayText == "¥1.23")
    }

    @Test("Rejects unsuccessful, missing, boolean, negative and non-finite amounts", arguments: [
        #"{}"#,
        #"{"success":true}"#,
        #"{"success":true,"data":{"rechargeAmount":100}}"#,
        #"{"success":false,"data":{"availableBalance":100}}"#,
        #"{"success":1,"data":{"availableBalance":100}}"#,
        #"{"data":{"availableBalance":100}}"#,
        #"{"success":true,"data":{"availableBalance":null}}"#,
        #"{"success":true,"data":{"availableBalance":true}}"#,
        #"{"success":true,"data":{"availableBalance":"NaN"}}"#,
        #"{"success":true,"data":{"availableBalance":"Infinity"}}"#,
        #"{"success":true,"data":{"availableBalance":-1}}"#,
        #"{"success":true,"data":{"availableBalance":""}}"#,
        #"<html>Sign in</html>"#
    ])
    func invalidPayload(payload: String) {
        #expect(throws: ZAIUsageService.ServiceError.self) {
            try ZAIBalanceParser.parse(Data(payload.utf8))
        }
    }

    @Test("Existing cache schema round-trips structured balances and reads older quota snapshots")
    func cacheCompatibility() throws {
        let quota = try ZAIBalanceParser.parse(balanceFixture, now: balanceNow)
        let encoded = try JSONEncoder().encode(QuotaCache.Snapshot(byProvider: [.zai: quota]))
        let decoded = try JSONDecoder().decode(QuotaCache.Snapshot.self, from: encoded)
        #expect(decoded.byProvider[.zai]?.remainingBalance == quota.remainingBalance)
        #expect(decoded.byProvider[.zai]?.capturedAt == balanceNow)
        let old = Data(#"{"zai":{"provider":"Z.ai","primary":{"usedPercent":20,"windowMinutes":300},"capturedAt":0}}"#.utf8)
        let legacy = try JSONDecoder().decode(QuotaCache.Snapshot.self, from: old)
        #expect(legacy.byProvider[.zai]?.primary.usedPercent == 20)
        #expect(legacy.byProvider[.zai]?.remainingBalance == nil)
    }

    @Test("Switching between a balance and a plan cannot resurrect old model windows")
    func modeBoundary() throws {
        let balance = try ZAIBalanceParser.parse(balanceFixture)
        let plan = ProviderQuota(provider: .zai, primary: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil), secondary: nil, planName: nil, capturedAt: .now)
        #expect(!UsageStore.quotaRoutesMatch(balance, plan))
        #expect(!UsageStore.quotaRoutesMatch(plan, balance))
        #expect(UsageStore.quotaRoutesMatch(balance, balance))
        #expect(UsageStore.quotaRoutesMatch(plan, plan))
    }
}

private actor BalanceRequestLog {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private func balanceHTTP(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private func balanceService(
    timeout: TimeInterval = 15,
    perform: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> ZAIUsageService {
    ZAIUsageService(
        region: .china, queryMode: .balance, balanceTimeout: timeout,
        loadLocalCandidates: { Issue.record("Balance mode must not discover ZCode credentials"); return [] },
        loadManualKey: { Issue.record("Routed balance validation must not read saved credentials"); return nil },
        loadStartPlanDeviceMid: { Issue.record("Balance mode must not read ZCode device data"); return nil },
        zcodeAppVersion: { Issue.record("Balance mode must not inspect ZCode"); return "" },
        perform: perform
    )
}

@Suite("BigModel API balance requests", .timeLimit(.minutes(1)))
struct ZAIBalanceServiceTests {
    @Test("Ordinary routed keys call only the explicit China balance endpoint")
    func requestContract() async throws {
        let log = BalanceRequestLog()
        let service = balanceService { request in
            await log.record(request)
            return (balanceFixture, balanceHTTP(request))
        }
        let quota = try await service.fetch(apiKey: " fixture-api-key ", region: .china, now: balanceNow)
        #expect(quota.remainingBalance?.amount == 123.45)
        let requests = await log.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://open.bigmodel.cn/api/biz/account/query-customer-account-report")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 10)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-api-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("Manual balance mode bypasses local discovery and uses the existing key source")
    func manualKey() async throws {
        var service = balanceService { request in (balanceFixture, balanceHTTP(request)) }
        service.loadManualKey = { "manual-fixture" }
        #expect(try await service.fetch().remainingBalance?.amount == 123.45)
    }

    @Test("An empty submitted key cannot fall back to another account")
    func emptyKey() async {
        let service = balanceService { request in
            Issue.record("Empty key must not send a request")
            return (balanceFixture, balanceHTTP(request))
        }
        do {
            _ = try await service.fetch(apiKey: " \n ", region: .china)
            Issue.record("Expected missingKey")
        } catch ZAIUsageService.ServiceError.missingKey {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Explicit balance mode cannot send a key to the global host")
    func rejectsGlobalBalance() async {
        let service = balanceService { request in
            Issue.record("An unsupported region must not send a request")
            return (balanceFixture, balanceHTTP(request))
        }
        do {
            _ = try await service.fetch(apiKey: "fixture", region: .global, queryMode: .balance)
            Issue.record("Expected region error")
        } catch ZAIUsageService.ServiceError.balanceRequiresChina {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Remembered China mode leaves the global Coding Plan contract intact")
    func globalCodingPlan() async throws {
        let log = BalanceRequestLog()
        let service = balanceService { request in
            await log.record(request)
            let body = request.url!.path().contains("subscription") ? #"{"data":[{"productName":"GLM Coding Pro"}]}"# : #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":20}]}}"#
            return (Data(body.utf8), balanceHTTP(request))
        }
        let quota = try await service.fetch(apiKey: "fixture", region: .global)
        #expect(quota.primary.usedPercent == 20)
        #expect(quota.planName == "GLM Coding Pro")
        #expect(quota.remainingBalance == nil)
        let requests = await log.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.host() == "api.z.ai" })
    }

    @Test("HTTP failures stay distinct and never trigger quota or region fallbacks", arguments: [401, 403, 429, 500])
    func httpFailures(status: Int) async {
        let log = BalanceRequestLog()
        let service = balanceService { request in
            await log.record(request)
            return (balanceFixture, balanceHTTP(request, status: status))
        }
        do {
            _ = try await service.fetch(apiKey: "fixture", region: .china)
            Issue.record("Expected HTTP failure")
        } catch ZAIUsageService.ServiceError.keyRejected(let code) {
            #expect([401, 403].contains(status))
            #expect(code == status)
        } catch ZAIUsageService.ServiceError.requestFailed(let code) {
            #expect(![401, 403].contains(status))
            #expect(code == status)
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(await log.requests.count == 1)
    }

    @Test("Business errors do not become no Coding Plan or a successful zero balance")
    func businessFailure() async {
        let service = balanceService { request in
            (Data(#"{"success":false,"msg":"coding plan fixture failure"}"#.utf8), balanceHTTP(request))
        }
        do {
            _ = try await service.fetch(apiKey: "fixture", region: .china)
            Issue.record("Expected business failure")
        } catch ZAIUsageService.ServiceError.balanceQueryFailed {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Transport timeout is preserved without a fallback")
    func transportFailure() async {
        let service = balanceService { _ in throw URLError(.timedOut) }
        do {
            _ = try await service.fetch(apiKey: "fixture", region: .china)
            Issue.record("Expected timeout")
        } catch let error as URLError { #expect(error.code == .timedOut) } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("A stalled request times out, receives cancellation, and can be retried")
    func timeoutAndRetry() async throws {
        let gate = BalanceWaitGate()
        let service = balanceService(timeout: 0.03) { request in
            await withTaskCancellationHandler { await gate.wait() } onCancel: { Task { await gate.cancelled() } }
            return (balanceFixture, balanceHTTP(request))
        }
        do {
            _ = try await service.fetch(apiKey: "fixture", region: .china)
            Issue.record("Expected deadline")
        } catch is AsyncDeadline.Failure {} catch { Issue.record("Unexpected error: \(error)") }
        try await gate.waitForCancellation()
        await gate.release()
        let retry = balanceService { request in (balanceFixture, balanceHTTP(request)) }
        #expect(try await retry.fetch(apiKey: "fixture", region: .china).remainingBalance?.amount == 123.45)
    }

    @Test("Cancelling an in-flight request rejects its late successful response")
    func cancellation() async throws {
        let gate = BalanceWaitGate()
        let service = balanceService { request in
            await withTaskCancellationHandler { await gate.wait() } onCancel: { Task { await gate.cancelled() } }
            return (balanceFixture, balanceHTTP(request))
        }
        let task = Task { try await service.fetch(apiKey: "fixture", region: .china) }
        try await gate.waitForStart()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        try await gate.waitForCancellation()
        await gate.release()
    }

    @Test("Mode preferences are optional and do not change existing defaults")
    func modePersistence() throws {
        let suite = "ZAIBalanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ZAIQueryModeStore(defaults: defaults)
        #expect(store.load() == .codingPlan)
        store.save(.balance)
        #expect(store.load() == .balance)
        defaults.set("unknown", forKey: ZAIQueryModeStore.defaultsKey)
        #expect(store.load() == .codingPlan)
    }
}

private actor BalanceWaitGate {
    var started = false
    var wasCancelled = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func cancelled() { wasCancelled = true }
    func release() { continuation?.resume(); continuation = nil }
    func waitForStart() async throws {
        for _ in 0..<200 { if started { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Request did not start")
    }
    func waitForCancellation() async throws {
        for _ in 0..<200 { if wasCancelled { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Cancellation did not reach request")
    }
}

@Suite("BigModel managed account routing")
struct ZAIBalanceAccountTests {
    private func profile() -> ProviderAccountProfile {
        ProviderAccountProfile(id: .managed(UUID()), provider: .zai, displayName: "Fixture",
                               kind: .managed, configurationDirectory: nil, isEnabled: true, createdAt: balanceNow)
    }

    @Test("Each account chooses its own China balance or legacy Coding Plan mode")
    func separateModes() async throws {
        let log = BalanceRequestLog()
        let fetcher = ProviderAccountFetchService(zaiUsageService: {
            balanceService { request in
                await log.record(request)
                let body = request.url!.path().contains("query-customer") ? balanceFixture
                    : Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":20}]}}"#.utf8)
                return (body, balanceHTTP(request))
            }
        })
        let balance = try await fetcher.fetch(profile(), now: balanceNow, credentialOverride: #"{"apiKey":"balance-fixture","region":"china","queryMode":"balance"}"#)
        let coding = try await fetcher.fetch(profile(), now: balanceNow, credentialOverride: #"{"apiKey":"coding-fixture","region":"china"}"#)
        #expect(balance.remainingBalance?.amount == 123.45)
        #expect(coding.remainingBalance == nil)
        #expect(coding.primary.usedPercent == 20)
        let requests = await log.requests
        #expect(requests.count == 3)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer balance-fixture")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer coding-fixture")
        #expect(requests.allSatisfy { $0.url?.host() == "open.bigmodel.cn" })
    }

    @Test("Unknown account modes fail before using any credential")
    func invalidMode() async {
        let fetcher = ProviderAccountFetchService(zaiUsageService: {
            Issue.record("Unknown mode must not construct a client")
            return balanceService { request in (balanceFixture, balanceHTTP(request)) }
        })
        await #expect(throws: ZAIUsageService.ServiceError.self) {
            try await fetcher.fetch(profile(), credentialOverride: #"{"apiKey":"fixture","region":"china","queryMode":"unknown"}"#)
        }
    }
}

#if TOKENREMAIN_CLOUD_SYNC
import TokenRemainSyncKit

@Suite("BigModel balance sync compatibility")
struct ZAIBalanceSyncTests {
    @Test("The existing redactor carries CNY without adding wire fields or leaking report totals")
    func syncRoundTrip() throws {
        let quota = try ZAIBalanceParser.parse(balanceFixture, now: balanceNow)
        let snapshot = MobileSnapshotRedactor.makeSnapshot(from: [.zai: quota], sourceInstanceID: UUID(), sequence: 1, generatedAt: balanceNow)
        #expect(snapshot.providers.first?.providerID == "zai")
        #expect(snapshot.providers.first?.windows.count == 1)
        #expect(snapshot.providers.first?.windows.first?.remainingBalance == SyncedQuotaBalance(amount: 123.45, currencyCode: "CNY"))
        let text = String(decoding: try snapshot.encodedPayload(), as: UTF8.self)
        #expect(!text.contains("rechargeAmount"))
        #expect(!text.contains("totalSpendAmount"))
        #expect(!text.contains("frozenBalance"))
        let restored = DirectSyncSnapshotAdapter.quotas(from: snapshot)
        #expect(restored[.zai]?.primary.remainingBalance == quota.primary.remainingBalance)
        #expect(restored[.zai]?.generalQuotaSummary.remainingBalance?.amount == 123.45)
        #expect(restored[.zai]?.capturedAt == balanceNow)
    }
}
#endif
