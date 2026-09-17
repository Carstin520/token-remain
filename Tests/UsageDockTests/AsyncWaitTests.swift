import Foundation
import Testing
@testable import UsageDock

/// Deliberately ignores task cancellation, like a callback or a blocked native
/// read. Each test releases it explicitly so no test worker is left behind.
private actor DelayedValidation {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private var released = false

    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Bounded asynchronous UI work", .timeLimit(.minutes(1)))
struct AsyncWaitTests {
    @Test("Deadline returns without waiting for an uncooperative callback")
    func deadline() async throws {
        let gate = DelayedValidation()
        let start = Date()
        do {
            _ = try await AsyncDeadline.run(timeout: 0.05) { await gate.wait(); return 1 }
            Issue.record("Expected timeout")
        } catch is AsyncDeadline.Failure {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(Date().timeIntervalSince(start) < 1)
        await gate.release()
        #expect(try await AsyncDeadline.run(timeout: 1) { 2 } == 2)
    }

    @Test("Cancellation returns without waiting for a callback that ignores it")
    func cancellation() async throws {
        let gate = DelayedValidation()
        let task = Task { try await AsyncDeadline.run { await gate.wait(); return 1 } }
        try await waitUntil { await gate.started }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        await gate.release()
    }

    @Test("Already cancelled work never starts its operation")
    func preCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AsyncDeadline.run {
                Issue.record("A cancelled operation must not start")
                return 1
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Views refuse duplicate submissions and become retryable after cancellation")
    @MainActor
    func viewAction() async throws {
        let action = AsyncViewAction()
        let gate = DelayedValidation()
        var count = 0
        action.start {
            count += 1
            _ = try? await AsyncDeadline.run { await gate.wait() }
        }
        #expect(action.isRunning)
        action.start { Issue.record("Duplicate submission") }
        try await waitUntil { await gate.started }
        action.cancel()
        try await waitUntil { @MainActor in !action.isRunning }
        #expect(count == 1)
        action.start { count += 1 }
        try await waitUntil { @MainActor in !action.isRunning }
        #expect(count == 2)
        await gate.release()
    }
}

@Suite("Credential and initial quota waiting state", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct CredentialWaitStateTests {
    @Test("Timeout preserves the previous credential and quota even after a late successful result")
    func timedOutValidation() async throws {
        let gate = DelayedValidation()
        let writes = CredentialWrites()
        let fixture = try Fixture(timeout: 0.05, writes: writes, validate: { provider, credential, _ in
            if credential == "delayed-demo" { await gate.wait() }
            return sampleQuota(provider, used: credential == "previous-demo" ? 20 : 99)
        })
        defer { fixture.remove() }
        #expect(await fixture.store.saveAPIKey("previous-demo", for: .deepseek))
        #expect(await fixture.store.saveAPIKey("delayed-demo", for: .deepseek) == false)
        #expect(writes.values == ["previous-demo"])
        #expect(fixture.store.quotaValue(for: .deepseek)?.primary.usedPercent == 20)
        #expect(fixture.store.providerNotices[.deepseek] == L10n.text("operation.timed_out"))
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(writes.values == ["previous-demo"])
        #expect(fixture.store.quotaValue(for: .deepseek)?.primary.usedPercent == 20)
        #expect(await fixture.store.saveAPIKey("retry-demo", for: .deepseek))
        #expect(writes.values == ["previous-demo", "retry-demo"])
    }

    @Test("Cancelling validation prevents a late Keychain write and permits immediate retry")
    func cancelledValidation() async throws {
        let gate = DelayedValidation()
        let writes = CredentialWrites()
        let fixture = try Fixture(writes: writes, validate: { provider, credential, _ in
            if credential == "delayed-demo" { await gate.wait() }
            return sampleQuota(provider, used: 30)
        })
        defer { fixture.remove() }
        let task = Task { await fixture.store.saveAPIKey("delayed-demo", for: .deepseek) }
        try await waitUntil { await gate.started }
        task.cancel()
        #expect(await task.value == false)
        #expect(writes.values.isEmpty)
        #expect(fixture.store.providerNotices[.deepseek] == L10n.text("operation.cancelled"))
        #expect(await fixture.store.saveAPIKey("retry-demo", for: .deepseek))
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(writes.values == ["retry-demo"])
        #expect(fixture.store.providerNotices[.deepseek] == nil)
    }

    @Test("A failed validation does not save the submitted credential")
    func failedValidation() async throws {
        let writes = CredentialWrites()
        let fixture = try Fixture(writes: writes, validate: { _, _, _ in throw URLError(.notConnectedToInternet) })
        defer { fixture.remove() }
        #expect(await fixture.store.saveAPIKey("demo-value", for: .deepseek) == false)
        #expect(writes.values.isEmpty)
        #expect(fixture.store.providerNotices[.deepseek] != nil)
    }

    @Test("Adding a secret account times out without publishing an unfinished profile")
    func secretAccountTimeout() async throws {
        let gate = DelayedValidation()
        let fixture = try Fixture(timeout: 0.05, accountFetch: { profile, _ in
            await gate.wait()
            return sampleQuota(profile.provider, used: 30)
        })
        defer { fixture.remove() }
        #expect(await fixture.store.addProviderAccount(
            provider: .deepseek, displayName: "Simulation", credential: "demo-value"
        ) == false)
        #expect(!fixture.store.addingProviderAccounts.contains(.deepseek))
        #expect(fixture.accounts.profiles.isEmpty)
        #expect(fixture.store.accountManagementNotice(for: .deepseek) == L10n.text("operation.timed_out"))
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.accounts.profiles.isEmpty)
    }

    @Test("Cancelling secret-account validation releases the adding state")
    func secretAccountCancellation() async throws {
        let gate = DelayedValidation()
        let fixture = try Fixture(accountFetch: { profile, _ in
            await gate.wait()
            return sampleQuota(profile.provider, used: 30)
        })
        defer { fixture.remove() }
        let task = Task { await fixture.store.addProviderAccount(
            provider: .deepseek, displayName: "Simulation", credential: "demo-value"
        ) }
        try await waitUntil { await gate.started }
        task.cancel()
        #expect(await task.value == false)
        #expect(!fixture.store.addingProviderAccounts.contains(.deepseek))
        #expect(fixture.accounts.profiles.isEmpty)
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.accounts.profiles.isEmpty)
    }

    @Test("Completed login closes the adding state even if initial quota is stalled")
    func loginAndInitialQuotaAreSeparate() async throws {
        let gate = DelayedValidation()
        let fixture = try Fixture(timeout: 0.05, accountFetch: { profile, _ in
            await gate.wait()
            return sampleQuota(profile.provider, used: 30)
        })
        defer { fixture.remove() }
        #expect(await fixture.store.addClaudeAccount())
        #expect(!fixture.store.isAddingClaudeAccount)
        #expect(fixture.store.accountLoginDeadlines.isEmpty)
        let profile = try #require(fixture.accounts.profiles.first)
        try await waitUntil { await gate.started }
        try await waitUntil { @MainActor in fixture.store.providerAccountStates[profile.id]?.isRefreshing == false }
        #expect(fixture.store.providerAccountStates[profile.id]?.notice == L10n.text("operation.timed_out"))
        #expect(fixture.store.providerAccountStates[profile.id]?.quota == nil)
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.store.providerAccountStates[profile.id]?.quota == nil)
        #expect(fixture.accounts.profiles.count == 1)
    }

    @Test("Removing an account during refresh cannot recreate its state")
    func removedAccountDoesNotReappear() async throws {
        let gate = DelayedValidation()
        let fixture = try Fixture(timeout: 0.05, accountFetch: { profile, _ in
            await gate.wait()
            return sampleQuota(profile.provider, used: 30)
        })
        defer { fixture.remove() }
        #expect(await fixture.store.addClaudeAccount())
        let profile = try #require(fixture.accounts.profiles.first)
        try await waitUntil { await gate.started }
        fixture.store.removeProviderAccount(profile.id)
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.store.providerAccountStates[profile.id] == nil)
        #expect(fixture.accounts.profiles.isEmpty)
    }

    @Test("An older Token Plan validation cannot overwrite a newer console account")
    @MainActor
    func tokenPlanReplacementRejectsLateResults() async throws {
        let gate = DelayedValidation()
        let writes = CredentialWrites()
        let fixture = try Fixture(writes: writes, validate: { provider, credential, _ in
            if credential == "older-fixture-config" { await gate.wait() }
            return sampleQuota(provider, used: credential == "older-fixture-config" ? 10 : 70)
        })
        defer { fixture.remove() }
        let older = Task { await fixture.store.saveAPIKey("older-fixture-config", for: .alibabaTokenPlan) }
        try await waitUntil { await gate.started }
        #expect(await fixture.store.saveAPIKey("newer-fixture-config", for: .alibabaTokenPlan))
        await gate.release()
        #expect(!(await older.value))
        #expect(writes.values == ["newer-fixture-config"])
        #expect(fixture.store.quotaValue(for: .alibabaTokenPlan)?.primary.usedPercent == 70)
    }

    @Test("Token Plan timeout retains the previous quota and never saves a late result")
    @MainActor
    func tokenPlanTimeoutPreservesPreviousAccount() async throws {
        let gate = DelayedValidation()
        let writes = CredentialWrites()
        let fixture = try Fixture(timeout: 0.03, writes: writes, validate: { provider, credential, _ in
            if credential == "slow-fixture-config" { await gate.wait() }
            return sampleQuota(provider, used: 40)
        })
        defer { fixture.remove() }
        #expect(await fixture.store.saveAPIKey("good-fixture-config", for: .alibabaTokenPlan))
        let capturedAt = fixture.store.quotaValue(for: .alibabaTokenPlan)?.capturedAt
        #expect(!(await fixture.store.saveAPIKey("slow-fixture-config", for: .alibabaTokenPlan)))
        #expect(fixture.store.quotaValue(for: .alibabaTokenPlan)?.capturedAt == capturedAt)
        #expect(fixture.store.providerNotices[.alibabaTokenPlan] == L10n.text("operation.timed_out"))
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(writes.values == ["good-fixture-config"])
        #expect(fixture.store.quotaValue(for: .alibabaTokenPlan)?.capturedAt == capturedAt)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let accounts: ProviderAccountsStore
        let store: UsageStore

        init(
            timeout: TimeInterval = 1,
            writes: CredentialWrites = CredentialWrites(),
            accountFetch: @escaping @Sendable (ProviderAccountProfile, String?) async throws -> ProviderQuota = { profile, _ in
                sampleQuota(profile.provider, used: 30)
            },
            validate: @escaping @Sendable (ProviderQuota.Provider, String, Date) async throws -> ProviderQuota = { provider, _, _ in
                sampleQuota(provider, used: 30)
            }
        ) throws {
            suite = "TokenRemainCredentialWaitTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appending(path: suite)
            accounts = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
            store = UsageStore(
                tracked: TrackedProvidersStore(defaults: defaults), defaults: defaults, home: root,
                sessionActivityMonitor: LocalAISessionActivityMonitor(sessionRoots: [], startMonitoring: false),
                providerAccountsStore: accounts, automaticallyStarts: false,
                quotaCache: QuotaCache(url: root.appending(path: "quota-cache.json")),
                quotaUsageHistoryCache: QuotaUsageHistoryCache(url: root.appending(path: "quota-history.json")),
                providerAccountQuotaCache: ProviderAccountQuotaCache(url: root.appending(path: "account-cache.json")),
                operationTimeout: timeout, credentialValidation: validate,
                credentialSave: { _, credential in writes.record(credential) },
                accountFetch: accountFetch, accountLogin: { _, _ in }
            )
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class CredentialWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
}

private func sampleQuota(_ provider: ProviderQuota.Provider, used: Double) -> ProviderQuota {
    ProviderQuota(provider: provider, primary: QuotaWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil),
                  secondary: nil, planName: "Test", capturedAt: .now)
}

private func waitUntil(_ predicate: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(await predicate())
}
