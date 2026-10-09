import Foundation
import Testing
@testable import UsageDock

@Suite("Grok Bot weekly quota")
struct GrokBotUsageTests {
    static let valid = Data(#"{"usagePercent":37.5,"hasNonZeroIncludedLimit":true,"grokPlanLabel":"Grok Bot Plan","nextResetTimestampUtc":"2026-10-17T01:00:00Z"}"#.utf8)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENREMAIN_GROKBOT_READONLY_PROBE"] == "1"))
    func readOnlyLiveProbe() async throws {
        let quota = try await GrokBotUsageService().fetch()
        #expect(quota.provider == .grokBot)
        #expect(quota.primary.usedPercent.isFinite)
        print("Grok Bot read-only request succeeded; server reset present: \(quota.primary.resetsAt != nil)")
    }

    @Test func weeklyQuotaIsIndependentFromCursorAndGrokCLI() throws {
        let quota = try GrokBotUsageService.parse(Self.valid)
        #expect(quota.provider == .grokBot)
        #expect(quota.primary.usedPercent == 37.5)
        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.primary.resetsAt != nil)
        #expect(quota.secondary == nil)
        #expect(ProviderQuota.Provider.grokBot.ccusageAgentID != ProviderQuota.Provider.grok.ccusageAgentID)
        #expect(!MobileSnapshotRedactor.publishedProviders.contains(.grokBot))
    }

    @Test(arguments: [
        #"{"usagePercent":0,"hasNonZeroIncludedLimit":false}"#,
        #"{"usagePercent":0,"includedLimitZero":true}"#
    ]) func noIncludedGrantNeverProducesFullQuota(json: String) {
        #expect(throws: GrokBotUsageService.ServiceError.notIncluded) { try GrokBotUsageService.parse(Data(json.utf8)) }
        #expect(UsageStore.invalidatesCachedQuota(GrokBotUsageService.ServiceError.notIncluded))
    }

    @Test func organizationManagedIsAStateWithoutPersonalPercentage() {
        let data = Data(#"{"usesPooledEnterpriseAllowance":true,"usagePercent":0}"#.utf8)
        #expect(throws: GrokBotUsageService.ServiceError.organizationManaged) { try GrokBotUsageService.parse(data) }
    }

    @Test(arguments: ["{}", #"{"hasNonZeroIncludedLimit":true}"#, #"{"usagePercent":0}"#, #"{"usagePercent":true,"hasNonZeroIncludedLimit":true}"#, #"{"usagePercent":-1,"hasNonZeroIncludedLimit":true}"#])
    func changedOrMissingFieldsAreUnknown(json: String) {
        #expect(throws: GrokBotUsageService.ServiceError.invalidResponse) { try GrokBotUsageService.parse(Data(json.utf8)) }
    }

    @Test func trialExpiryIsNeverUsedAsReset() throws {
        let data = Data(#"{"hasNonZeroIncludedLimit":false,"usagePercent":0,"sandTrialExpiresAt":"2026-10-20T00:00:00Z","currentPeriodStart":"2026-10-10T00:00:00Z"}"#.utf8)
        let quota = try GrokBotUsageService.parse(data, now: Date(timeIntervalSince1970: 0))
        #expect(quota.primary.resetsAt == nil)
        #expect(quota.primary.windowMinutes == 0)
        #expect(quota.planName != "Grok Bot")
    }

    @Test func requestUsesReadOnlyCursorAuthAndFixedBody() async throws {
        let quota = try await GrokBotUsageService().fetch(readAuth: { .init(accessToken: "fixture-token", membershipType: nil) }) { request in
            #expect(request.url == GrokBotUsageService.url)
            #expect(request.httpMethod == "POST")
            #expect(request.httpBody == Data("{}".utf8))
            #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
            return (Self.valid, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(quota.provider == .grokBot)
    }

    @Test func deadlineIncludesCredentialDiscoveryAndCancellationStopsTransport() async throws {
        do {
            _ = try await GrokBotUsageService().fetch(timeout: 0.03, readAuth: {
                try? await Task.sleep(for: .seconds(30))
                return .init(accessToken: "fixture-token", membershipType: nil)
            }) { _ in
                Issue.record("Late auth must not reach transport")
                throw URLError(.unknown)
            }
            Issue.record("Expected timeout")
        } catch is AsyncDeadline.Failure {}
        let task = Task {
            try await GrokBotUsageService().fetch(readAuth: { .init(accessToken: "fixture-token", membershipType: nil) }) { _ in
                try await Task.sleep(for: .seconds(30))
                throw URLError(.unknown)
            }
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        try await requestUsesReadOnlyCursorAuthAndFixedBody()
    }

    @Test func olderCacheReadersKeepTheirKnownProviders() throws {
        let bot = try GrokBotUsageService.parse(Self.valid)
        let cursor = ProviderQuota(provider: .cursor, primary: bot.primary, secondary: nil, planName: nil, capturedAt: .now)
        let snapshot = QuotaCache.Snapshot(byProvider: [.cursor: cursor, .grokBot: bot])
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let legacyQuotas = try #require(object["quotas"] as? [String: Any])
        #expect(legacyQuotas["Grok Bot"] == nil)
        #expect(legacyQuotas["Cursor"] != nil)
        #expect(try JSONDecoder().decode(QuotaCache.Snapshot.self, from: data).byProvider[.grokBot] != nil)
        let history = QuotaUsageHistory.empty.recording(cursor).recording(bot)
        let encodedHistory = try JSONEncoder().encode(history)
        struct OldHistory: Decodable { let samples: [QuotaUsageHistory.Sample] }
        #expect(try JSONDecoder().decode(OldHistory.self, from: encodedHistory).samples.map(\.provider) == [.cursor])
        #expect(try JSONDecoder().decode(QuotaUsageHistory.self, from: encodedHistory).samples.count == 2)
    }
}
