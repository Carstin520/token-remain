import Foundation
import Testing
@testable import UsageDock

@Suite("Account login UI state", .serialized)
@MainActor
struct AccountLoginStateTests {
    @Test("Cancelling returns the UI to idle, discards the unfinished profile, and permits retry")
    func cancelAndRetry() async throws {
        let fixture = try Fixture { _, _ in try await Task.sleep(for: .seconds(20)) }
        defer { fixture.remove() }
        for _ in 0..<2 {
            let attempt = Task { await fixture.store.addClaudeAccount() }
            try await waitForLogin(fixture.store)
            #expect(fixture.store.isAddingClaudeAccount)
            fixture.store.cancelProviderAccountLogin(.claude)
            #expect(await attempt.value == false)
            expectIdle(fixture)
            #expect(fixture.store.accountManagementNotice == L10n.text("accounts.login_cancelled"))
        }
    }

    @Test("A cancelled parent task cancels the login it is awaiting")
    func parentCancellation() async throws {
        let fixture = try Fixture { _, _ in try await Task.sleep(for: .seconds(20)) }
        defer { fixture.remove() }
        let attempt = Task { await fixture.store.addClaudeAccount() }
        try await waitForLogin(fixture.store)
        attempt.cancel()
        #expect(await attempt.value == false)
        expectIdle(fixture)
    }

    @Test("Timeout removes the spinner and shows a retryable message")
    func timeoutState() async throws {
        let fixture = try Fixture { _, _ in throw AccountLoginProcessRunner.Failure.timedOut }
        defer { fixture.remove() }
        #expect(await fixture.store.addClaudeAccount() == false)
        expectIdle(fixture)
        #expect(fixture.store.accountManagementNotice == L10n.text("accounts.login_timed_out"))
    }

    @Test("A cancelled operation that returns normally still cannot publish an account")
    func cancellationRacingWithSuccess() async throws {
        let fixture = try Fixture { _, _ in try? await Task.sleep(for: .seconds(20)) }
        defer { fixture.remove() }
        let attempt = Task { await fixture.store.addClaudeAccount() }
        try await waitForLogin(fixture.store)
        fixture.store.cancelProviderAccountLogin(.claude)
        #expect(await attempt.value == false)
        expectIdle(fixture)
    }

    private func waitForLogin(_ store: UsageStore) async throws {
        let deadline = Date().addingTimeInterval(2)
        while store.accountLoginDeadlines[.claude] == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(store.accountLoginDeadlines[.claude] != nil)
    }

    private func expectIdle(_ fixture: Fixture) {
        #expect(!fixture.store.isAddingClaudeAccount)
        #expect(fixture.store.accountLoginDeadlines.isEmpty)
        #expect(fixture.accounts.profiles.isEmpty)
        #expect(!fixture.store.providerAccountProfiles.contains { !$0.isSystem })
        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: fixture.root.appending(path: "claude"), includingPropertiesForKeys: nil
        )) ?? []
        #expect(remaining.isEmpty)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let accounts: ProviderAccountsStore
        let store: UsageStore

        init(login: @escaping @Sendable (ProviderQuota.Provider, URL) async throws -> Void) throws {
            suite = "TokenRemainLoginStateTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appending(path: suite)
            accounts = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
            store = UsageStore(
                tracked: TrackedProvidersStore(defaults: defaults), defaults: defaults, home: root,
                sessionActivityMonitor: LocalAISessionActivityMonitor(sessionRoots: [], startMonitoring: false),
                providerAccountsStore: accounts, automaticallyStarts: false, accountLogin: login
            )
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
