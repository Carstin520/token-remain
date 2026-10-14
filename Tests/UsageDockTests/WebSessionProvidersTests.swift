import Foundation
import Testing
@testable import UsageDock

// Fixtures are hand-written from the response shapes documented in CodexBar's
// providers; every cookie value is a fake placeholder.

@Suite("Web Cookie header")
struct WebCookieHeaderTests {
    @Test("Raw values, Cookie: lines and quoted copies normalize to one header")
    func normalizes() {
        #expect(WebCookieHeader.normalized("a=1; b=two") == "a=1; b=two")
        #expect(WebCookieHeader.normalized("Cookie: a=1;b=2;") == "a=1; b=2")
        #expect(WebCookieHeader.normalized("'session=x'") == "session=x")
        #expect(WebCookieHeader.normalized("not a cookie") == nil)
        #expect(WebCookieHeader.normalized("bad name=1") == nil)
        #expect(WebCookieHeader.normalized("a=1\nb=2") == nil)
    }

    @Test("Clipboard import reads Copy as cURL, header blocks and raw cookies only")
    func extractsFromClipboard() {
        let chromeCurl = """
        curl 'https://muse.ai/' \\
          -H 'accept: text/html' \\
          -b 'session=fake-a; theme=dark' \\
          -H 'user-agent: Mozilla'
        """
        #expect(WebCookieHeader.extract(fromClipboard: chromeCurl) == "session=fake-a; theme=dark")

        let headerCurl = #"curl "https://ampcode.com/settings" -H "Cookie: session=fake-b""#
        #expect(WebCookieHeader.extract(fromClipboard: headerCurl) == "session=fake-b")

        let block = "accept: */*\ncookie: access-token=fake.jwt.x; other=1\nreferer: https://app.factory.ai/"
        #expect(WebCookieHeader.extract(fromClipboard: block) == "access-token=fake.jwt.x; other=1")

        #expect(WebCookieHeader.extract(fromClipboard: "_session=fake-c") == "_session=fake-c")
        // A lone API key or unrelated text must never become a Cookie.
        #expect(WebCookieHeader.extract(fromClipboard: "sk-live-abcdef") == nil)
        #expect(WebCookieHeader.extract(fromClipboard: "line one\nline two") == nil)
        #expect(WebCookieHeader.value(named: "access-token", in: "a=1; access-token=tok") == "tok")
    }
}

@Suite("Muse (muse.ai) usage")
struct MuseUsageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let paidFlight = """
    0:{"a":"$@1","f":"","b":"build"}
    1:{"success":true,"subscription":{"tier":{"name":"Maximum"},"usage":{"percentUsed":3,"resetsAt":1790634838},"usageRowValueLabel":"3% used (2.8B tokens left)","topupBalance":60000000,"topupTotal":80000000,"agreement":{"currentPeriodEndTime":1790721238}}}
    """

    @Test("Paid subscription maps to a weekly window, plan and top-up balance")
    func parsesPaid() throws {
        let quota = try MuseUsageService.parse(Data(paidFlight.utf8), now: now)
        #expect(quota.provider == .muse)
        #expect(quota.primary.usedPercent == 3)
        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_790_634_838))
        #expect(quota.planName == "Maximum")
        #expect(quota.accountBalance == QuotaBalance(amount: 60, currencyCode: "USD"))
        #expect(quota.secondary == nil)
    }

    @Test("Free plan has no top-up; failures and missing usage are rejected")
    func parsesFreeAndRejects() throws {
        let free = #"1:{"success":true,"subscription":{"tier":{"name":"Muse Free"},"usage":{"percentUsed":128,"resetsAt":1790634838},"agreement":null}}"#
        let quota = try MuseUsageService.parse(Data(free.utf8), now: now)
        #expect(quota.primary.usedPercent == 100)
        #expect(quota.accountBalance == nil)
        #expect(throws: (any Error).self) {
            try MuseUsageService.parse(Data(#"1:{"success":false}"#.utf8), now: now)
        }
    }

    @Test("Action discovery follows the settings preload to its loader chunk")
    func discoversActionID() {
        let page = #"<script src="/_next/static/chunks/app.js"></script><script src="/_next/static/chunks/loader.js">"#
        #expect(MuseUsageService.chunkPaths(in: page) == [
            "/_next/static/chunks/app.js", "/_next/static/chunks/loader.js"
        ])
        let scanned = #"e.A(434304).then(({preloadHatchSettingsData:e})=>e({}))"#
            + #"},56115,s=>{s.v(t=>Promise.all(["static/chunks/other.js"]))},"#
            + #"434304,s=>{s.v(t=>Promise.all(["static/chunks/settings.js"].map(t=>s.l(t))))}"#
        #expect(MuseUsageService.settingsChunkPaths(in: scanned) == ["/_next/static/chunks/settings.js"])
        let id = String(repeating: "ab", count: 21)
        let settings = #"(0,d.createServerReference)(""# + id
            + #"",d.callServer,void 0,d.findSourceMapURL,"fetchSubscriptionAction")"#
        #expect(MuseUsageService.subscriptionActionID(in: settings) == id)
        #expect(MuseUsageService.subscriptionActionID(in: #"createServerReference("abc","x")"#) == nil)
    }

    @Test("A cached action is used directly; a stale one is rediscovered and replaced")
    func actionCacheLifecycle() async throws {
        let staleID = String(repeating: "0", count: 40)
        let freshID = String(repeating: "f", count: 40)
        let recorder = RequestRecorder()
        let flight = paidFlight
        var service = MuseUsageService()
        service.transport = { request in
            await recorder.record(request)
            let path = request.url?.path ?? ""
            let action = request.value(forHTTPHeaderField: "Next-Action")
            func reply(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if action == staleID { return reply(404, "Server action not found.") }
            if action == freshID { return reply(200, flight) }
            switch path {
            case "/": return reply(200, #"<script src="/_next/static/chunks/app.js"></script>"#)
            case "/_next/static/chunks/app.js":
                return reply(200, #"e.A(7).then(({preloadHatchSettingsData:e})=>e({}))},7,s=>{s.v(t=>Promise.all(["static/chunks/settings.js"]))}"#)
            case "/_next/static/chunks/settings.js":
                return reply(200, #"(0,d.createServerReference)(""# + freshID + #"",d.callServer,void 0,d.findSourceMapURL,"fetchSubscriptionAction")"#)
            default: return reply(404, "")
            }
        }
        let stored = StoredValue(staleID)
        service.loadActionID = { stored.value }
        service.storeActionID = { stored.value = $0 }

        let quota = try await service.fetch(cookie: "session=fake", now: now)
        #expect(quota.primary.usedPercent == 3)
        #expect(stored.value == freshID)
        let requests = await recorder.requests
        // Static chunks never carry the session cookie.
        #expect(requests.filter { $0.url?.path.hasPrefix("/_next/") == true }
            .allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        #expect(requests.first?.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
    }

    @Test("A login redirect means the session expired")
    func signedOut() async {
        var service = MuseUsageService()
        service.loadActionID = { String(repeating: "a", count: 40) }
        service.storeActionID = { _ in }
        service.transport = { request in
            (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 307, httpVersion: nil,
                headerFields: ["Location": "https://auth.muse.ai/login"]
            )!)
        }
        await #expect(throws: MuseUsageService.ServiceError.sessionExpired) {
            try await service.fetch(cookie: "session=fake", now: now)
        }
    }
}

@Suite("Muse Code usage")
struct MuseCodeUsageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Team quota maps to the 5-hour window and the weekly limit")
    func parsesQuota() throws {
        #expect(try MuseCodeUsageParser.teamIDs(Data(#"{"teams":[{"team_id":"42","team_name":"Me"},{"team_id":"x"}]}"#.utf8)) == ["42"])
        let body = #"{"subscription_quota":{"tier":"High Usage","window_weighted_used":"250","window_weighted_limit":"1000","window_resets_at":1790003600,"window_duration_secs":18000,"weekly_weighted_used":"3000","weekly_weighted_limit":"10000","weekly_resets_at":1790500000}}"#
        let quota = try #require(try MuseCodeUsageParser.parseQuota(Data(body.utf8), now: now))
        #expect(quota.provider == .museCode)
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
        #expect(quota.secondary?.usedPercent == 30)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.planName == "High Usage")
    }

    @Test("An idle or elapsed 5-hour window reads as unused; no quota tries the next team")
    func idleWindow() throws {
        let idle = #"{"subscription_quota":{"window_weighted_used":"900","window_weighted_limit":"1000","window_resets_at":1789000000,"window_duration_secs":18000,"weekly_weighted_used":"1","weekly_weighted_limit":"10","weekly_resets_at":1790500000}}"#
        let quota = try #require(try MuseCodeUsageParser.parseQuota(Data(idle.utf8), now: now))
        #expect(quota.primary.usedPercent == 0)
        #expect(quota.primary.resetsAt == nil)
        #expect(try MuseCodeUsageParser.parseQuota(Data(#"{"subscription_quota":null}"#.utf8), now: now) == nil)
    }
}

@Suite("Amp usage")
struct AmpUsageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Amp Free replenishment becomes a rolling window")
    func parsesFree() throws {
        let text = "Signed in as dev@example.com\nAmp Free: $7.50 / $10 remaining (replenishes +$0.42 / hour)\nIndividual credits: $3.25 remaining"
        let quota = try AmpUsageParser.parse(displayText: text, now: now)
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.windowMinutes == 24 * 60)
        #expect(quota.planName == "Amp Free")
        #expect(quota.accountBalance == QuotaBalance(amount: 3.25, currencyCode: "USD"))
    }

    @Test("A paid tier leads; Amp Free stays as a named sibling")
    func parsesPaidTier() throws {
        let text = """
        **Amp Pro Tier:** agent usage $30 of $120 remaining, period 2026-10-01 to 2026-11-01 - resets upon renewal in 12 days
        Amp Free: 80% remaining today (resets daily)
        """
        let quota = try AmpUsageParser.parse(displayText: text, now: now)
        #expect(quota.planName == "Pro")
        #expect(quota.primary.usedPercent == 75)
        #expect(quota.primary.resetsAt == now.addingTimeInterval(12 * 86_400))
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["amp_free"])
        #expect(quota.uniqueScopedWindows.first?.window.usedPercent == 20)
    }

    @Test("API envelope errors and the settings-page fallback")
    func envelopeAndFallback() throws {
        let ok = #"{"ok":true,"result":{"displayText":"Amp Free: $5 / $10 remaining"}}"#
        #expect(try AmpUsageParser.parseBalanceResponse(Data(ok.utf8), now: now).primary.usedPercent == 50)
        #expect(throws: ExtendedProviderError.self) {
            try AmpUsageParser.parseBalanceResponse(Data(#"{"ok":false,"error":{"code":"auth-required"}}"#.utf8), now: now)
        }
        let html = #"<script>self.__data={freeTierUsage:{"quota":1000,"used":250,"hourlyReplenishment":42,"windowHours":24}}</script>"#
        let page = try AmpUsageParser.parseSettingsPage(html, now: now)
        #expect(page.primary.usedPercent == 25)
        #expect(page.primary.windowMinutes == 1440)
    }
}

@Suite("Factory usage")
struct FactoryUsageTests {
    @Test("The busier of Standard and Premium leads the billing period")
    func parsesPools() throws {
        let body = #"{"usage":{"startDate":1789000000000,"endDate":1791592000000,"standard":{"userTokens":100,"totalAllowance":1000,"usedRatio":0.1},"premium":{"orgTotalTokensUsed":600,"totalAllowance":1000}}}"#
        let quota = try FactoryUsageParser.parse(Data(body.utf8))
        #expect(quota.provider == .factory)
        #expect(quota.primary.poolName == "Premium")
        #expect(quota.primary.usedPercent == 60)
        #expect(quota.primary.windowMinutes == 43_200)
        #expect(quota.primary.resetsAt == Date(timeIntervalSince1970: 1_791_592_000))
        #expect(quota.uniqueScopedWindows.map(\.scopeID) == ["factory_standard"])
        #expect(quota.uniqueScopedWindows.first?.window.usedPercent == 10)
        #expect(throws: ExtendedProviderError.self) {
            try FactoryUsageParser.parse(Data(#"{"usage":{}}"#.utf8))
        }
    }
}

@Suite("Augment usage")
struct AugmentUsageTests {
    @Test("Credits and the subscription cycle end")
    func parsesCredits() throws {
        let credits = #"{"usageUnitsRemaining":750,"usageUnitsConsumedThisBillingCycle":250,"usageUnitsAvailable":0}"#
        let subscription = #"{"planName":"Developer","billingPeriodEnd":"2026-11-01T00:00:00Z"}"#
        let quota = try AugmentUsageParser.parse(credits: Data(credits.utf8), subscription: Data(subscription.utf8))
        #expect(quota.primary.usedPercent == 25)
        #expect(quota.primary.remainingCredits == 750)
        #expect(quota.planName == "Developer")
        #expect(quota.primary.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        // The subscription detail is optional.
        let bare = try AugmentUsageParser.parse(credits: Data(credits.utf8), subscription: nil)
        #expect(bare.planName == nil)
    }
}

@Suite("Web Cookie guide specs")
@MainActor
struct WebCookieGuideSpecTests {
    @Test("Every Cookie-only provider except Claude has a guide")
    func everyCookieProviderHasGuide() {
        let cookieProviders = ProviderSecretStore.descriptors.filter(\.isCookie).map(\.provider)
        for provider in cookieProviders where provider != .claude && provider != .alibabaTokenPlan {
            #expect(WebCookieGuideSpec.spec(for: provider) != nil, "\(provider) lacks a Cookie guide")
        }
        let alibaba = WebCookieGuideSpec.alibaba(region: .international, edition: .personal)
        let stored = try? AlibabaTokenPlanConfiguration.decode(alibaba.encode("csrf=fake; a=b") ?? "")
        #expect(stored?.region == .international)
        #expect(stored?.edition == .personal)
    }

    @Test("New web-session providers stay desktop-only in sync")
    func desktopOnly() {
        for provider in [ProviderQuota.Provider.muse, .museCode, .amp, .factory, .augment] {
            #expect(!MobileSnapshotRedactor.publishedProviders.contains(provider))
        }
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private final class StoredValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    init(_ value: String?) { stored = value }
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
