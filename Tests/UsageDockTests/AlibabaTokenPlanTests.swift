import Foundation
import Testing
@testable import UsageDock

@Suite("Alibaba Token Plan")
struct AlibabaTokenPlanTests {
    private let now = Date(timeIntervalSince1970: 1_789_660_800)
    private let teamJSON = #"{"Success":true,"Data":{"TotalValue":2000,"TotalSurplusValue":1250,"CycleEndTime":1792252800000}}"#

    private func config(_ edition: AlibabaTokenPlanConfiguration.Edition = .team,
                        region: AlibabaTokenPlanConfiguration.Region = .china,
                        cookie: String = "session=fixture-only; login_aliyunid_csrf=fake-csrf; sec_token=fake-nonce") -> AlibabaTokenPlanConfiguration {
        AlibabaTokenPlanConfiguration(region: region, edition: edition, cookie: cookie)
    }

    @Test func teamCreditsAreNotMoneyAndZeroIsReal() throws {
        let quota = try AlibabaTokenPlanUsageService.parse(Data(teamJSON.utf8), configuration: config(), now: now)
        #expect(quota.provider == .alibabaTokenPlan)
        #expect(quota.primary.usedPercent == 37.5)
        #expect(quota.primary.remainingCredits == 1250)
        #expect(quota.primary.remainingBalance == nil)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_792_252_800))
        #expect(quota.capturedAt == now)
        let exhausted = teamJSON.replacingOccurrences(of: "1250", with: "0")
        let empty = try AlibabaTokenPlanUsageService.parse(Data(exhausted.utf8), configuration: config(), now: now)
        #expect(empty.primary.usedPercent == 100)
        #expect(empty.primary.remainingCredits == 0)
        #expect(!QuotaWindowRow.remainingValueText(remainingPercent: 62.5, remainingBalance: nil, remainingCredits: 1250).contains("$"))
    }

    @Test func expiryIsNotResetAndEmbeddedBodyDecodes() throws {
        let body = teamJSON.replacingOccurrences(of: "CycleEndTime", with: "NearestExpireDate")
        let envelope = try JSONSerialization.data(withJSONObject: ["successResponse": ["body": body]])
        let quota = try AlibabaTokenPlanUsageService.parse(envelope, configuration: config(), now: now)
        #expect(quota.primary.remainingCredits == 1250)
        #expect(quota.primary.resetsAt == nil)
    }

    @Test func personalRatiosAndIndependentWindows() throws {
        let data = Data(#"{"success":true,"DataV2":{"per5HourPercentage":0.25,"per5HourResetTime":1790000000000,"per1WeekPercentage":0.8}}"#.utf8)
        let quota = try AlibabaTokenPlanUsageService.parse(data, configuration: config(.personal), now: now)
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.usedPercent == 80)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(quota.secondary?.resetsAt == nil)
        #expect(quota.primary.remainingCredits == nil)
        let weeklyOnly = try AlibabaTokenPlanUsageService.parse(Data(#"{"per1WeekPercentage":0}"#.utf8), configuration: config(.personal), now: now)
        #expect(weeklyOnly.primary.windowMinutes == 10080)
        #expect(weeklyOnly.primary.usedPercent == 0)
        #expect(weeklyOnly.secondary == nil)
    }

    @Test(arguments: [
        #"{"TotalValue":0,"TotalSurplusValue":0}"#,
        #"{"TotalValue":200,"TotalSurplusValue":300}"#,
        #"{"TotalValue":200}"#,
        #"{"TotalValue":true,"TotalSurplusValue":0}"#,
        #"{"TotalValue":"NaN","TotalSurplusValue":0}"#,
        #"{"Data":{"TotalCount":1,"EquityList":[{"TotalValue":200,"TotalSurplusValue":100}]}}"#,
        #"{"per5HourPercentage":0.3}"#,
        #"{"success":false,"Data":{"TotalValue":200,"TotalSurplusValue":100}}"#
    ]) func invalidTeamDataDoesNotBecomeFullQuota(_ json: String) {
        #expect(throws: (any Error).self) {
            try AlibabaTokenPlanUsageService.parse(Data(json.utf8), configuration: config(), now: now)
        }
    }

    @Test(arguments: [#"{"per5HourPercentage":true}"#, #"{"per5HourPercentage":25}"#,
                      #"{"per5HourPercentage":-0.2}"#, #"{"per5HourPercentage":"inf"}"#,
                      #"{"per5HourPercentage":null}"#, #"{"data":{}}"#])
    func invalidPersonalDataDoesNotBecomeFullQuota(_ json: String) {
        #expect(throws: (any Error).self) {
            try AlibabaTokenPlanUsageService.parse(Data(json.utf8), configuration: config(.personal), now: now)
        }
    }

    @Test func allRegionsAndEditionsHaveFixedDestinationsAndForms() throws {
        for region in AlibabaTokenPlanConfiguration.Region.allCases {
            for edition in AlibabaTokenPlanConfiguration.Edition.allCases {
                let config = config(edition, region: region)
                let request = try AlibabaTokenPlanUsageService.usageRequest(config, secToken: "nonce+with&symbols")
                #expect(request.httpMethod == "POST")
                #expect(request.url?.scheme == "https")
                #expect(request.url?.host == URL(string: edition == .team ? region.origin : region.personalOrigin)?.host)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Cookie") == config.cookie)
                #expect(request.value(forHTTPHeaderField: "x-xsrf-token") == "fake-csrf")
                #expect(!request.httpShouldHandleCookies)
                #expect(request.timeoutInterval == 12)
                let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
                let fields = try #require(URLComponents(string: "https://unused.invalid/?\(body)")?.queryItems)
                #expect(fields.first { $0.name == "sec_token" }?.value == "nonce+with&symbols")
                let paramsText = try #require(fields.first { $0.name == "params" }?.value)
                let params = try #require(JSONSerialization.jsonObject(with: Data(paramsText.utf8)) as? [String: Any])
                if edition == .team {
                    #expect(params["ProductCode"] as? String == (region == .china ? "sfm_tokenplanteams_dp_cn" : "sfm_tokenplanteams_dp_intl"))
                } else {
                    #expect(params["Api"] as? String == "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage")
                    #expect(!paramsText.contains("switchAgent"))
                }
            }
        }
    }

    @Test(arguments: ["sk-ws-fake", "session=fixture", "session=fixture\r\nInjected: true; csrf=fake", "csrf=x; csrf=y"])
    func rejectsAPIKeysIncompleteAndInjectedCookies(_ cookie: String) {
        #expect(throws: (any Error).self) { try config(cookie: cookie).cookieValues() }
    }

    @Test func nonceIsReadOnlyAndNotPersistedInConfiguration() async throws {
        let config = config(cookie: "session=fixture; csrf=fake")
        let recorder = RequestRecorder()
        let service = AlibabaTokenPlanUsageService(transport: { request in
            await recorder.append(request)
            let text = request.httpMethod == "GET" ? #"<script>window.ALIYUN_CONSOLE_CONFIG={SEC_TOKEN: "fake-nonce"}</script>"# : teamJSON
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "should-not-be-saved=fake"])!)
        })
        let quota = try await service.fetch(configuration: config.encoded(), now: now)
        #expect(quota.primary.remainingCredits == 1250)
        let requests = await recorder.values
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(String(decoding: requests[1].httpBody!, as: UTF8.self).contains("sec_token=fake-nonce"))
        #expect(!requests[1].value(forHTTPHeaderField: "Cookie")!.contains("should-not-be-saved"))
        #expect(!config.cookie.contains("fake-nonce"))
    }

    @Test func errorsNeverIncludeResponseOrSecrets() async throws {
        for status in [302, 401, 403, 429, 500] {
            let service = AlibabaTokenPlanUsageService(transport: { request in
                (Data("private-response-marker".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            do {
                _ = try await service.fetch(configuration: config().encoded())
                Issue.record("Expected an HTTP failure")
            } catch {
                #expect(!error.localizedDescription.contains("private-response-marker"))
                #expect(!error.localizedDescription.contains("fixture-only"))
            }
        }
        let nested = Data(#"{"successResponse":{"body":"{\"success\":false,\"errorCode\":\"BailianGateway.NotLogined\",\"message\":\"private-response-marker\"}"}}"#.utf8)
        #expect(throws: (any Error).self) { try AlibabaTokenPlanUsageService.payload(nested) }
    }

    @Test func cancellationAndDeadlineReachTransportAndRetryWorks() async throws {
        let recorder = CancellationRecorder()
        let slow = AlibabaTokenPlanUsageService(transport: { _ in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { await recorder.cancelled(); throw error }
            throw AlibabaTokenPlanError.unavailable
        }, timeout: 0.03)
        let raw = try config().encoded()
        do {
            _ = try await slow.fetch(configuration: raw)
            Issue.record("Expected timeout")
        } catch { #expect(error is AsyncDeadline.Failure) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorder.count == 1)
        let pending = Task { try await slow.fetch(configuration: raw) }
        try await Task.sleep(for: .milliseconds(5))
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        let fast = AlibabaTokenPlanUsageService(transport: { request in
            (Data(teamJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await fast.fetch(configuration: raw).primary.remainingCredits == 1250)
    }

    @Test func creditsCacheIsOptionalAndNotInMobileAllowlist() throws {
        let old = Data(#"{"usedPercent":25,"windowMinutes":300,"resetsAt":null}"#.utf8)
        #expect(try JSONDecoder().decode(QuotaWindow.self, from: old).remainingCredits == nil)
        let quota = try AlibabaTokenPlanUsageService.parse(Data(teamJSON.utf8), configuration: config(), now: now)
        let encoded = try JSONEncoder().encode(quota)
        #expect(try JSONDecoder().decode(ProviderQuota.self, from: encoded).primary.remainingCredits == 1250)
        #expect(!MobileSnapshotRedactor.publishedProviders.contains(.alibabaTokenPlan))
        let snapshot = MobileSnapshotRedactor.makeSnapshot(from: [.alibabaTokenPlan: quota], sourceInstanceID: UUID(), sequence: 1, generatedAt: now)
        #expect(snapshot.providers.isEmpty)
    }
}

private actor RequestRecorder {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}
private actor CancellationRecorder {
    var count = 0
    func cancelled() { count += 1 }
}
