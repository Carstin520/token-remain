import Foundation
import Testing
@testable import UsageDock

@Suite("Windsurf usage")
struct WindsurfUsageServiceTests {
    @Test("Windsurf SeatManagement response remains a distinct provider")
    func parsesQuota() throws {
        let data = Data(#"""
        {
          "userStatus": {"planStatus": {
            "planInfo": {"planName": "Pro", "hideDailyQuota": false},
            "dailyQuotaRemainingPercent": 72,
            "weeklyQuotaRemainingPercent": 40,
            "dailyQuotaResetAtUnix": 1784005200,
            "weeklyQuotaResetAtUnix": 1784500000
          }}
        }
        """#.utf8)
        let quota = try WindsurfUsageParser.parse(data)
        #expect(quota.provider == .windsurf)
        #expect(quota.primary.usedPercent == 28)
        #expect(quota.primary.windowMinutes == 1_440)
        #expect(quota.secondary?.usedPercent == 60)
        #expect(quota.planName == "Pro")
    }

    @Test("Only the Windsurf auth fields are decoded from editor state")
    func parsesAuthState() throws {
        let data = Data(#"""
        {"apiKey":"wk-test", "apiServerUrl":"https://server.codeium.com/", "email":"private@example.com"}
        """#.utf8)
        let auth = try #require(WindsurfAuthReader.parse(data))
        #expect(auth.apiKey == "wk-test")
        #expect(auth.apiServerURL == "https://server.codeium.com")
    }

    @Test("Environment login is testable without reading a real editor database")
    func environmentAuth() async throws {
        var reader = WindsurfAuthReader()
        reader.environment = [
            "WINDSURF_API_KEY": "wk-env",
            "WINDSURF_API_SERVER_URL": "https://enterprise.example.com/"
        ]
        let auth = try #require(await reader.load())
        #expect(auth.apiKey == "wk-env")
        #expect(auth.apiServerURL == "https://enterprise.example.com")
    }
}
