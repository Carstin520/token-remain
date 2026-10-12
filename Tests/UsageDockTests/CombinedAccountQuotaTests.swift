import Foundation
import Testing
@testable import UsageDock

@Suite("Optional combined account quota")
struct CombinedAccountQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Equal plans add account units without clamping the total to 100")
    func combinedWindowsAndResets() throws {
        let a = snapshot("A", used: 20, weekly: 50, resetAfter: 60)
        let b = snapshot("B", used: 30, weekly: 60, resetAfter: 120)
        let group = try CombinedAccountQuota.evaluate([b, a], now: now).get()
        #expect(group.windows[0].remaining == 150)
        #expect(group.windows[0].capacity == 200)
        #expect(group.windows[0].remaining / group.windows[0].capacity == 0.75)
        #expect(group.windows[1].remaining == 90)
        #expect(group.windows[1].capacity == 200)
        #expect(group.windows[0].segments.map(\.name) == ["A", "B"])
        #expect(group.windows[1].segments.map(\.id) == group.windows[0].segments.map(\.id))
        #expect(group.windows[0].nextReset == now.addingTimeInterval(60))
        #expect(group.windows[0].nextRestored == 20)
        #expect(group.windows[0].segments[1].resetsAt == now.addingTimeInterval(120))
    }

    @Test("Paused accounts never contribute and missing managed readings never disappear")
    func enabledAndUnavailable() throws {
        let a = snapshot("A", used: 20)
        let b = snapshot("B", used: 30)
        var paused = snapshot("Paused", used: 0)
        paused = ProviderAccountSnapshot(profile: {
            var profile = paused.profile; profile.isEnabled = false; return profile
        }(), state: paused.state)
        let group = try CombinedAccountQuota.evaluate([a, b, paused], now: now).get()
        #expect(group.accountCount == 2)
        let unavailable = ProviderAccountSnapshot(profile: snapshot("Missing", used: 0).profile, state: .init())
        expectFailure([a, b, unavailable], .readings)
        let placeholder = ProviderAccountSnapshot(profile: .system(.claude), state: .init())
        #expect(try CombinedAccountQuota.evaluate([a, b, placeholder], now: now).get().accountCount == 2)
        expectFailure([a, b, ProviderAccountSnapshot(profile: .system(.claude), state: .init(notice: "fixture failure"))], .readings)
        expectFailure([a], .accounts)
        expectFailure([a, a], .accounts)
    }

    @Test("Different or unknown tiers cannot enable equal-capacity display")
    func incompatiblePlans() {
        expectFailure([snapshot("A", used: 20), snapshot("B", used: 30, plan: "Max 5x")], .plans)
        for plan in [nil, "", "Max", "Team", "Enterprise", "Unknown"] as [String?] {
            expectFailure([snapshot("A", used: 20, plan: plan), snapshot("B", used: 30, plan: plan)], .plans)
        }
    }

    @Test("Missing, mismatched, non-percent, expired or routed windows keep separate displays")
    func incompatibleWindows() {
        let a = snapshot("A", used: 20)
        expectFailure([a, snapshot("B", used: 30, weekly: nil)], .windows)
        expectFailure([a, snapshot("B", used: 30, minutes: 60)], .windows)
        expectFailure([a, snapshot("B", used: 30, resetAfter: 0)], .windows)
        expectFailure([a, changedPrimary(snapshot("B", used: 30)) {
            $0.remainingBalance = QuotaBalance(amount: 1, currencyCode: "USD")
        }], .windows)
        expectFailure([a, changedPrimary(snapshot("B", used: 30)) { $0.remainingCredits = 20 }], .windows)
        expectFailure([a, changed(snapshot("B", used: 30)) {
            $0.attribution = QuotaAttribution(provider: .deepseek, displayName: "Fixture route", routeIdentifier: "test")
        }], .windows)
        expectFailure([a, changed(snapshot("B", used: 30)) {
            $0.scopedWindows = [ScopedQuotaWindow(scopeID: "extra", displayName: "Extra",
                window: QuotaWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil))]
        }], .windows)
        let failing = ProviderAccountSnapshot(profile: a.profile, state: .init(quota: a.quota, notice: "fixture error"))
        expectFailure([failing, snapshot("B", used: 30)], .readings)
    }

    @Test("Invalid percentages are not silently made into a plausible total")
    func invalidPercentages() {
        for used in [Double.nan, .infinity, -1, 101] {
            expectFailure([snapshot("A", used: 20), snapshot("B", used: used)], .windows)
        }
    }

    @Test("Named pools remain distinct and simultaneous resets restore only their used portions")
    func scopedPoolsAndSharedReset() throws {
        let scope = ScopedQuotaWindow(scopeID: "fable", displayName: "Fable",
            window: QuotaWindow(usedPercent: 75, windowMinutes: 10_080, resetsAt: nil))
        let a = changed(snapshot("A", used: 20)) { $0.scopedWindows = [scope] }
        let b = changed(snapshot("B", used: 30)) { $0.scopedWindows = [scope] }
        let group = try CombinedAccountQuota.evaluate([a, b], now: now).get()
        #expect(group.windows.count == 3)
        #expect(group.windows[2].remaining == 50)
        #expect(group.windows[2].capacity == 200)
        #expect(group.windows[2].nextReset == nil)
        #expect(group.windows[0].nextRestored == 50)
    }

    @Test("Consent defaults off, persists locally, and is invalidated by changed membership or plan")
    @MainActor
    func consentPersistence() throws {
        let suite = "CombinedAccountTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        let a = snapshot("A", used: 20), b = snapshot("B", used: 30)
        let group = try CombinedAccountQuota.evaluate([a, b], now: now).get()
        #expect(!preferences.combinesAccounts(for: .claude, group: group))
        preferences.setCombinedAccountConsent(group.consentFingerprint, for: .claude)
        let restored = PreferencesStore(defaults: defaults)
        #expect(restored.combinesAccounts(for: .claude, group: group))
        #expect(!restored.combinesAccounts(for: .codex, group: group))
        let refreshedA = ProviderAccountSnapshot(profile: a.profile, state: .init(quota: quota(used: 60)))
        let refreshed = try CombinedAccountQuota.evaluate([b, refreshedA], now: now).get()
        #expect(restored.combinesAccounts(for: .claude, group: refreshed))
        let replacement = try CombinedAccountQuota.evaluate([a, snapshot("New", used: 30)], now: now).get()
        #expect(!restored.combinesAccounts(for: .claude, group: replacement))
        let tierChanged = try CombinedAccountQuota.evaluate([
            ProviderAccountSnapshot(profile: a.profile, state: .init(quota: quota(used: 20, plan: "Max 5x"))),
            ProviderAccountSnapshot(profile: b.profile, state: .init(quota: quota(used: 30, plan: "Max 5x")))
        ], now: now).get()
        #expect(!restored.combinesAccounts(for: .claude, group: tierChanged))
        restored.setCombinedAccountConsent(nil, for: .claude)
        #expect(!PreferencesStore(defaults: defaults).combinesAccounts(for: .claude, group: group))
    }

    private func snapshot(_ name: String, used: Double, weekly: Double? = 40,
                          plan: String? = "Pro", minutes: Int = 300, resetAfter: TimeInterval = 60) -> ProviderAccountSnapshot {
        let profile = ProviderAccountProfile(id: .managed(UUID()), provider: .claude, displayName: name,
            kind: .managed, configurationDirectory: nil, isEnabled: true, createdAt: now)
        return ProviderAccountSnapshot(profile: profile,
            state: .init(quota: quota(used: used, weekly: weekly, plan: plan, minutes: minutes, resetAfter: resetAfter)))
    }

    private func quota(used: Double, weekly: Double? = 40, plan: String? = "Pro",
                       minutes: Int = 300, resetAfter: TimeInterval = 60) -> ProviderQuota {
        ProviderQuota(provider: .claude,
            primary: QuotaWindow(usedPercent: used, windowMinutes: minutes, resetsAt: now.addingTimeInterval(resetAfter)),
            secondary: weekly.map { QuotaWindow(usedPercent: $0, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3600)) },
            planName: plan, capturedAt: now)
    }

    private func changed(_ snapshot: ProviderAccountSnapshot, mutate: (inout ProviderQuota) -> Void) -> ProviderAccountSnapshot {
        var quota = snapshot.quota!
        mutate(&quota)
        return ProviderAccountSnapshot(profile: snapshot.profile, state: .init(quota: quota))
    }

    private func changedPrimary(_ snapshot: ProviderAccountSnapshot, mutate: (inout QuotaWindow) -> Void) -> ProviderAccountSnapshot {
        let original = snapshot.quota!
        var primary = original.primary
        mutate(&primary)
        return ProviderAccountSnapshot(profile: snapshot.profile, state: .init(quota: ProviderQuota(
            provider: original.provider, primary: primary, secondary: original.secondary,
            planName: original.planName, capturedAt: original.capturedAt)))
    }

    private func expectFailure(_ snapshots: [ProviderAccountSnapshot], _ expected: CombinedAccountQuota.Unavailable) {
        switch CombinedAccountQuota.evaluate(snapshots, now: now) {
        case .success: Issue.record("Expected \(expected)")
        case .failure(let actual): #expect(actual == expected)
        }
    }
}
