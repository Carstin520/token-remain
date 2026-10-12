import Foundation
import Testing
@testable import UsageDock

@Suite("Account management", .serialized)
@MainActor
struct AccountManagementTests {
    @Test("Removing one account preserves siblings, another app, and the system login")
    func independentRemoval() async throws {
        let fixture = try Fixture(providers: [.openrouter, .openrouter, .claude])
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let first = fixture.profiles[0]
        let sibling = fixture.profiles[1]
        let other = fixture.profiles[2]
        store.setAccountSelection(.account(first.id), for: .openrouter)
        await store.refreshProviderAccount(first.id)
        await store.refreshProviderAccount(sibling.id)

        store.removeProviderAccount(first.id)

        #expect(fixture.deletedSecrets.ids == [first.id])
        #expect(store.providerAccountStates[first.id] == nil)
        #expect(fixture.accountCache.load()[first.id] == nil)
        #expect(fixture.accountCache.load()[sibling.id] != nil)
        #expect(store.accountSelection(for: .openrouter) == .all)
        #expect(store.providerAccountProfiles.contains { $0.id == sibling.id })
        #expect(store.providerAccountProfiles.contains { $0.id == other.id })
        #expect(store.providerAccountProfiles.contains { $0.id == .system(.openrouter) })
        #expect(FileManager.default.fileExists(atPath: try #require(other.configurationDirectory)))

        let reloaded = ProviderAccountsStore(defaults: fixture.defaults, rootDirectory: fixture.root, deleteSecret: { _ in })
        #expect(Set(reloaded.profiles.map(\.id)) == [sibling.id, other.id])
        #expect(reloaded.selection(for: .openrouter) == .all)
    }

    @Test("A lone unavailable and paused managed account can be removed while its app is stopped")
    func removeLastPausedAccount() throws {
        let fixture = try Fixture(providers: [.openrouter])
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let profile = fixture.profiles[0]
        fixture.tracked.setEnabled(.openrouter, false)
        store.setProviderAccountEnabled(false, id: profile.id)
        #expect(store.accountSnapshots(for: .openrouter).map(\.id) == [profile.id])

        store.removeProviderAccount(profile.id)
        store.removeProviderAccount(profile.id) // A repeated action cannot delete another account.

        #expect(fixture.accounts.profiles.isEmpty)
        #expect(fixture.deletedSecrets.ids == [profile.id])
        #expect(!fixture.tracked.isEnabled(.openrouter))
        #expect(store.providerAccountProfiles.contains { $0.id == .system(.openrouter) })
    }

    @Test("The system account cannot be removed or paused through management actions")
    func protectsSystemAccount() throws {
        let fixture = try Fixture(providers: [.claude])
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        store.removeProviderAccount(.system(.claude))
        store.setProviderAccountEnabled(false, id: .system(.claude))
        #expect(store.providerAccountProfiles.first { $0.id == .system(.claude) }?.isEnabled == true)
        #expect(fixture.deletedSecrets.ids.isEmpty)
        #expect(fixture.accounts.profiles == fixture.profiles)
    }

    @Test("Stopping an app preserves all accounts and prevents individual reads until resumed")
    func stopAndResume() async throws {
        let fixture = try Fixture(providers: [.openrouter, .openrouter, .claude])
        defer { fixture.cleanUp() }
        let calls = FetchCalls()
        let store = fixture.makeStore { profile, _ in
            await calls.record(profile.id)
            return Self.quota(profile.provider)
        }
        let first = fixture.profiles[0]
        fixture.tracked.setEnabled(.openrouter, false)
        store.setProviderAccountEnabled(false, id: first.id)
        store.setProviderAccountEnabled(true, id: first.id)
        await store.refreshProviderAccount(first.id)
        await store.refreshProviderAccount(fixture.profiles[1].id)
        // Give any fire-and-forget refresh scheduled by re-enabling a chance to run.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await calls.ids.isEmpty)
        #expect(fixture.accounts.profiles == fixture.profiles)
        #expect(fixture.deletedSecrets.ids.isEmpty)
        #expect(fixture.tracked.isEnabled(.claude))
        #expect(!TrackedProvidersStore(defaults: fixture.defaults).isEnabled(.openrouter))

        fixture.tracked.setEnabled(.openrouter, true)
        await store.refreshProviderAccount(first.id)
        #expect(await calls.ids == [first.id])
        #expect(store.providerAccountStates[first.id]?.quota != nil)
    }

    @Test("Stopped apps do not contribute cached account quotas to Dock and other headlines")
    func stoppedAppHidesCachedHeadline() async throws {
        let fixture = try Fixture(providers: [.openrouter, .openrouter, .claude])
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        for profile in fixture.profiles { await store.refreshProviderAccount(profile.id) }
        let strategy = QuotaSummaryStrategy.shortestWindow
        #expect(store.headlineQuota(for: .openrouter, strategy: strategy) != nil)

        fixture.tracked.setEnabled(.openrouter, false)

        #expect(store.headlineQuota(for: .openrouter, strategy: strategy) == nil)
        #expect(!store.headlineQuotas.contains { $0.provider == .openrouter })
        #expect(store.headlineQuota(for: .claude, strategy: strategy) != nil)
        #expect(fixture.profiles.allSatisfy { store.providerAccountStates[$0.id]?.quota != nil })
        #expect(fixture.accounts.profiles == fixture.profiles)

        fixture.tracked.setEnabled(.openrouter, true)
        #expect(store.headlineQuota(for: .openrouter, strategy: strategy) != nil)
        store.removeProviderAccount(fixture.profiles[0].id)
        #expect(store.headlineQuota(for: .openrouter, strategy: strategy) != nil)
        store.removeProviderAccount(fixture.profiles[1].id)
        #expect(store.headlineQuota(for: .openrouter, strategy: strategy) == nil)
        #expect(store.headlineQuota(for: .claude, strategy: strategy) != nil)
    }

    @Test("A refresh finishing after removal cannot restore the account or its cache")
    func lateRefreshAfterRemoval() async throws {
        let fixture = try Fixture(providers: [.openrouter])
        defer { fixture.cleanUp() }
        let store = fixture.makeStore { profile, _ in
            try await Task.sleep(for: .milliseconds(100))
            return Self.quota(profile.provider)
        }
        let id = fixture.profiles[0].id
        let refresh = Task { await store.refreshProviderAccount(id) }
        let deadline = Date().addingTimeInterval(2)
        while store.providerAccountStates[id]?.isRefreshing != true, Date() < deadline {
            await Task.yield()
        }
        #expect(store.providerAccountStates[id]?.isRefreshing == true)
        store.removeProviderAccount(id)
        await refresh.value
        #expect(store.providerAccountStates[id] == nil)
        #expect(fixture.accountCache.load()[id] == nil)
        #expect(!store.providerAccountProfiles.contains { $0.id == id })
    }

    nonisolated private static func quota(_ provider: ProviderQuota.Provider) -> ProviderQuota {
        ProviderQuota(
            provider: provider,
            primary: QuotaWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil),
            secondary: nil, planName: "Test", capturedAt: .now
        )
    }

    private actor FetchCalls {
        var ids: [ProviderAccountID] = []
        func record(_ id: ProviderAccountID) { ids.append(id) }
    }

    private final class DeletedSecrets {
        var ids: [ProviderAccountID] = []
    }

    @MainActor
    private struct Fixture {
        let suite: String
        let root: URL
        let defaults: UserDefaults
        let accounts: ProviderAccountsStore
        let tracked: TrackedProvidersStore
        let profiles: [ProviderAccountProfile]
        let deletedSecrets: DeletedSecrets
        let accountCache: ProviderAccountQuotaCache

        init(providers: [ProviderQuota.Provider]) throws {
            suite = "TokenRemainAccountManagementTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appending(path: suite)
            let deleted = DeletedSecrets()
            deletedSecrets = deleted
            let accountStore = ProviderAccountsStore(defaults: defaults, rootDirectory: root, deleteSecret: {
                deleted.ids.append($0.id)
            })
            accounts = accountStore
            tracked = TrackedProvidersStore(defaults: defaults)
            tracked.completeOnboarding(enabled: Set(providers))
            profiles = try providers.enumerated().map { index, provider in
                let profile = try accountStore.prepareProfile(provider: provider, displayName: "Test \(index)")
                accountStore.commit(profile)
                return profile
            }
            accountCache = ProviderAccountQuotaCache(url: root.appending(path: "accounts.json"))
        }

        func makeStore(
            fetch: @escaping @Sendable (ProviderAccountProfile, String?) async throws -> ProviderQuota = { profile, _ in
                AccountManagementTests.quota(profile.provider)
            }
        ) -> UsageStore {
            UsageStore(
                tracked: tracked, defaults: defaults, home: root,
                sessionActivityMonitor: LocalAISessionActivityMonitor(sessionRoots: [], startMonitoring: false),
                providerAccountsStore: accounts, automaticallyStarts: false,
                quotaCache: QuotaCache(url: root.appending(path: "quota.json")),
                quotaUsageHistoryCache: QuotaUsageHistoryCache(url: root.appending(path: "history.json")),
                providerAccountQuotaCache: accountCache,
                credentialValidation: { _, _, _ in throw CancellationError() },
                credentialSave: { _, _ in Issue.record("Unexpected credential write") },
                accountFetch: fetch, accountLogin: { _, _ in throw CancellationError() }
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
