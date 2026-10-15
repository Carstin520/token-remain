import Foundation
import Testing
import TokenRemainSyncKit
@testable import UsageDock

@Suite("Grok Bot usage parser")
struct GrokBotUsageParserTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test("Parses the weekly percentage, protobuf Timestamp reset and Grok plan label")
    func parsesWeeklyUsage() throws {
        let payload = """
        {
          "currentPeriodStart": "2026-10-12T00:00:00Z",
          "nextResetTimestampUtc": "2026-10-19T00:00:00.123456789Z",
          "usagePercent": 37.5,
          "hasNonZeroIncludedLimit": true,
          "usesPooledEnterpriseAllowance": false,
          "grokPlanLabel": "unified_ultra",
          "isUnified": true,
          "cursorPlanName": "pro",
          "billingBrand": "SAND_BILLING_BRAND_GROK",
          "isTeamSeat": false,
          "onDemandSettings": {"visible": true, "eligible": true, "enabled": false}
        }
        """
        let quota = try GrokBotUsageParser.parse(Data(payload.utf8), now: now)

        #expect(quota.provider == .grokBot)
        #expect(quota.primary.usedPercent == 37.5)
        #expect(quota.primary.windowMinutes == 7 * 24 * 60)
        let reset = try #require(quota.primary.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_792_368_000.123) < 0.001)
        #expect(quota.secondary == nil)
        #expect(quota.scopedWindows == nil)
        #expect(quota.planName == "Unified Ultra")
        #expect(quota.capturedAt == now)
    }

    @Test("Clamps out-of-range percentages and falls back to the Cursor plan name")
    func clampsAndFallsBack() throws {
        let over = try GrokBotUsageParser.parse(
            Data(#"{"usagePercent": 140, "nextResetTimestampUtc": "2026-10-19T00:00:00Z", "cursorPlanName": "pro"}"#.utf8),
            now: now
        )
        #expect(over.primary.usedPercent == 100)
        #expect(over.primary.resetsAt == Date(timeIntervalSince1970: 1_792_368_000))
        #expect(over.planName == "Pro")

        let negative = try GrokBotUsageParser.parse(Data(#"{"usagePercent": -3}"#.utf8), now: now)
        #expect(negative.primary.usedPercent == 0)
        #expect(negative.primary.resetsAt == nil)
        #expect(negative.planName == nil)
    }

    @Test("A pooled enterprise allowance is reported, not shown as a weekly percentage")
    func pooledAllowanceIsNotAPercentage() {
        let payload = #"{"usagePercent": 12, "usesPooledEnterpriseAllowance": true}"#
        #expect(throws: GrokBotUsageService.ServiceError.pooledAllowance) {
            try GrokBotUsageParser.parse(Data(payload.utf8), now: now)
        }
    }

    @Test("A missing usage percentage means no weekly allowance rather than 0%")
    func missingPercentageIsNoAllowance() {
        let payload = #"{"hasNonZeroIncludedLimit": false, "cursorPlanName": "free"}"#
        #expect(throws: GrokBotUsageService.ServiceError.noWeeklyAllowance) {
            try GrokBotUsageParser.parse(Data(payload.utf8), now: now)
        }
    }

    @Test("Malformed bodies are invalid responses")
    func malformedBody() {
        #expect(throws: GrokBotUsageService.ServiceError.invalidResponse) {
            try GrokBotUsageParser.parse(Data("<html>".utf8), now: now)
        }
    }

    @Test("Plan labels are title-cased with underscores split")
    func planLabels() {
        #expect(GrokBotUsageParser.planLabel("super") == "Super")
        #expect(GrokBotUsageParser.planLabel("unified_ultra") == "Unified Ultra")
        #expect(GrokBotUsageParser.planLabel("  ") == nil)
        #expect(GrokBotUsageParser.planLabel(nil) == nil)
    }
}

@Suite("Grok Bot usage service")
struct GrokBotUsageServiceTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test("Posts an empty Connect request with the Cursor bearer token")
    func requestShape() async throws {
        let recorder = GrokBotRequestRecorder()
        var service = GrokBotUsageService()
        service.loadAuth = { [now] in
            CursorAuthReader.Auth(accessToken: Self.fixtureToken(expiry: now.addingTimeInterval(3600)), membershipType: "pro")
        }
        service.transport = { request in
            await recorder.append(request)
            return (Data(#"{"usagePercent": 5}"#.utf8), Self.response(request, status: 200))
        }

        let quota = try await service.fetch(now: now)

        #expect(quota.primary.usedPercent == 5)
        let request = try #require(await recorder.values.first)
        #expect(request.url?.absoluteString == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(request.timeoutInterval == 10)
    }

    @Test("Without a Cursor IDE login the service asks for one and sends nothing")
    func notLoggedIn() async {
        let recorder = GrokBotRequestRecorder()
        var service = GrokBotUsageService()
        service.loadAuth = { nil }
        service.transport = { request in
            await recorder.append(request)
            return (Data(), Self.response(request, status: 200))
        }
        await #expect(throws: GrokBotUsageService.ServiceError.notLoggedIn) {
            try await service.fetch(now: now)
        }
        #expect(await recorder.values.isEmpty)
    }

    @Test("An expired Cursor token is stale and is never sent or refreshed")
    func expiredTokenIsStale() async {
        let recorder = GrokBotRequestRecorder()
        var service = GrokBotUsageService()
        service.loadAuth = { [now] in
            CursorAuthReader.Auth(accessToken: Self.fixtureToken(expiry: now.addingTimeInterval(-60)), membershipType: nil)
        }
        service.transport = { request in
            await recorder.append(request)
            return (Data(), Self.response(request, status: 200))
        }
        await #expect(throws: GrokBotUsageService.ServiceError.staleLogin) {
            try await service.fetch(now: now)
        }
        #expect(await recorder.values.isEmpty)
    }

    @Test("401/403 map to a stale login and other statuses to request failures")
    func httpStatuses() async {
        for (status, expected) in [
            (401, GrokBotUsageService.ServiceError.staleLogin),
            (403, .staleLogin),
            (500, .requestFailed(500))
        ] {
            var service = GrokBotUsageService()
            service.loadAuth = { CursorAuthReader.Auth(accessToken: "opaque-fixture", membershipType: nil) }
            service.transport = { request in (Data(), Self.response(request, status: status)) }
            await #expect(throws: expected) {
                try await service.fetch(now: now)
            }
        }
    }

    private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// Unsigned fixture JWT carrying only `exp`; never a real credential.
    private static func fixtureToken(expiry: Date) -> String {
        let payload = Data(#"{"exp":\#(Int(expiry.timeIntervalSince1970))}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "fixture.\(payload).signature"
    }
}

@Suite("Grok Bot provider wiring")
struct GrokBotProviderWiringTests {
    @Test("Detects the installed Grok Bot app without reading its secrets")
    func detectsInstalledApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-grokbot-detection-\(UUID().uuidString)", isDirectory: true)
        let home = root.appending(path: "home")
        let applications = root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func installed() -> Bool? {
            TrackedProvidersStore.detections(
                home: home,
                environment: [:],
                applicationDirectories: [applications],
                includeManualCredentials: false
            ).first { $0.provider == .grokBot }?.installed
        }

        #expect(installed() == false)
        try FileManager.default.createDirectory(
            at: applications.appending(path: "Grok Bot.app"),
            withIntermediateDirectories: true
        )
        #expect(installed() == true)
    }

    @Test("Grok Bot is its own provider next to Grok and stays desktop-only in sync")
    func providerIdentity() {
        let order = ProviderQuota.Provider.displayOrder
        #expect(order.firstIndex(of: .grokBot) == order.firstIndex(of: .grok).map { $0 + 1 })
        #expect(ProviderQuota.Provider(rawValue: "Grok Bot") == .grokBot)
        #expect(PopoverWidget.grokBot.provider == .grokBot)
        #expect(PopoverLayoutStore.defaultHidden.contains(.grokBot))
        #expect(UsageStore.auxProviders.contains(.grokBot))
        #expect(MobileSnapshotRedactor.stableID(for: .grokBot) == "grok-bot")
        #expect(!MobileSnapshotRedactor.publishedProviders.contains(.grokBot))
        #expect(!SyncedProviderID.supportedOnCurrentMobile.contains("grok-bot"))
    }
}

private actor GrokBotRequestRecorder {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}
