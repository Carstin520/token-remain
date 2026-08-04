import Foundation
import Testing
@testable import UsageDock

@Suite("P1 compatible providers")
struct ProviderCompatibilityP1Tests {
    @Test("GLM Team JSON config and quota preserve the team provider identity")
    func zaiTeam() throws {
        let configuration = try #require(ZAITeamConfiguration.parse(
            #"{"apiKey":"k","organization":"org","project":"project"}"#
        ))
        #expect(configuration.apiKey == "k")
        #expect(configuration.organizationID == "org")
        #expect(configuration.projectID == "project")

        let payload = Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":50}]}}"#.utf8)
        let quota = try ZAITeamUsageService.parse(payload)
        #expect(quota.provider == .zaiTeam)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.planName == "Team")
    }

    @Test("New API account config strips terminal v1 and converts quota units")
    func newAPIAccount() throws {
        let configuration = try #require(ThirdPartyConfiguration.parse(
            #"{"adapter":"newapi-account","baseUrl":"https://relay.example.com/v1","accessToken":"token","userId":"42"}"#
        ))
        #expect(configuration.baseURL.absoluteString == "https://relay.example.com")
        #expect(configuration.userID == "42")

        let quotaData = Data(#"{"success":true,"data":{"quota":5000000,"used_quota":2500000}}"#.utf8)
        let statusData = Data(#"{"success":true,"data":{"quota_per_unit":500000}}"#.utf8)
        let quota = try ThirdPartyUsageService.parse(
            quotaData: quotaData,
            statusData: statusData,
            configuration: configuration
        )
        #expect(quota.provider == .thirdParty)
        #expect(quota.primary.remainingBalance == QuotaBalance(amount: 10, currencyCode: "USD"))
        #expect(abs(quota.primary.usedPercent - (5.0 / 15.0 * 100)) < 0.0001)
        #expect(quota.spend?.allTimeUSD == 5)
    }

    @Test("New API token and custom mappings reject unsafe paths")
    func tokenAndCustom() throws {
        let tokenConfiguration = try #require(ThirdPartyConfiguration.parse(
            #"{"adapter":"newapi-token","baseUrl":"https://relay.example.com","apiKey":"sk-test"}"#
        ))
        let tokenData = Data(#"{"success":true,"data":{"total_available":1000000,"total_used":500000,"expires_at":1893456000}}"#.utf8)
        let tokenQuota = try ThirdPartyUsageService.parse(
            quotaData: tokenData,
            statusData: Data(#"{"data":{"quota_per_unit":500000}}"#.utf8),
            configuration: tokenConfiguration
        )
        #expect(tokenQuota.primary.remainingBalance == QuotaBalance(amount: 2, currencyCode: "USD"))
        #expect(tokenQuota.primary.resetsAt == Date(timeIntervalSince1970: 1_893_456_000))

        let custom = try #require(ThirdPartyConfiguration.parse(
            #"{"adapter":"custom","baseUrl":"https://balance.example.com","apiKey":"k","endpointPath":"/user/balance","authMode":"x-api-key","remainingPath":"data.balance","usedPath":"data.used","currency":"CNY","divisor":100}"#
        ))
        let customQuota = try ThirdPartyUsageService.parse(
            quotaData: Data(#"{"data":{"balance":1234,"used":766}}"#.utf8),
            statusData: nil,
            configuration: custom
        )
        #expect(customQuota.primary.remainingBalance == QuotaBalance(amount: 12.34, currencyCode: "CNY"))
        #expect(customQuota.spend == nil)
        #expect(ThirdPartyConfiguration.normalizedEndpointPath("/../admin") == nil)
        #expect(ThirdPartyConfiguration.normalizedJSONPath("data.__proto__.x") == nil)
        #expect(ThirdPartyConfiguration.normalizedBaseURL("http://relay.example.com") == nil)
        #expect(ThirdPartyConfiguration.normalizedBaseURL("http://localhost:3000") != nil)
    }
}
