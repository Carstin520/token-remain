import Foundation
import Testing
@testable import UsageDock

@Suite("Provider accounts")
struct ProviderAccountsTests {
    @Test("All-accounts summary keeps percentages separate and sums balances by currency")
    func summaryUsesSafeAggregates() {
        var first = quota(used: 15, weeklyUsed: 40)
        first.accountBalance = QuotaBalance(amount: 12.5, currencyCode: " usd ")
        var second = quota(used: 92, weeklyUsed: 35)
        second.accountBalance = QuotaBalance(amount: 7.5, currencyCode: "USD")
        var third = quota(used: 25, weeklyUsed: nil)
        third.accountBalance = QuotaBalance(amount: 30, currencyCode: "CNY")

        let snapshots = [
            snapshot(name: "Current", quota: first),
            snapshot(name: "Work", quota: second),
            snapshot(name: "Disabled", quota: third, enabled: false),
            snapshot(name: "Unavailable", quota: nil)
        ]
        let summary = ProviderAccountSummary(snapshots: snapshots)

        #expect(summary.accountCount == 3)
        #expect(summary.availableCount == 2)
        #expect(summary.lowAccountCount == 1)
        #expect(summary.lowestRemainingPercent == 8)
        #expect(summary.balancesByCurrency == ["USD": 20])
    }

    @Test("Managed profile metadata and selection survive a store reload")
    @MainActor
    func profilePersistence() throws {
        let suite = "TokenRemainProviderAccounts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "tokenremain-accounts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let store = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
        let prepared = try store.prepareClaudeProfile(displayName: " Work ")
        let directory = try #require(prepared.configurationDirectory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
        #expect(permissions & 0o077 == 0)
        #expect(prepared.displayName == "Work")

        store.commit(prepared)
        store.rename(prepared.id, to: "Team")
        store.setEnabled(false, for: prepared.id)
        store.setSelection(.account(prepared.id), for: .claude)

        let restored = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
        #expect(restored.allProfiles.first?.id == .system(.claude))
        #expect(restored.profiles.count == 1)
        #expect(restored.profiles.first?.displayName == "Team")
        #expect(restored.profiles.first?.isEnabled == false)
        #expect(restored.selection(for: .claude) == .account(prepared.id))

        #expect(restored.remove(prepared.id)?.id == prepared.id)
        #expect(restored.selection(for: .claude) == .all)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test("Multi-account capability is explicit and keeps active-app-only providers disabled")
    func capabilityMatrix() {
        #expect(ProviderQuota.Provider.claude.multiAccountCapability?.credentialKind == .isolatedCLI)
        #expect(ProviderQuota.Provider.codex.multiAccountCapability?.credentialKind == .isolatedCLI)
        #expect(ProviderQuota.Provider.codex.multiAccountCapability?.allowsLocalActivation == false)
        #expect(ProviderQuota.Provider.openrouter.multiAccountCapability?.credentialKind == .keychainSecret)
        #expect(ProviderQuota.Provider.grok.multiAccountCapability?.credentialKind == .keychainSecret)
        #expect(ProviderQuota.Provider.antigravity.multiAccountCapability?.credentialKind == .keychainSecret)
        #expect(ProviderQuota.Provider.opencode.multiAccountCapability == nil)
        #expect(ProviderQuota.Provider.kiro.multiAccountCapability == nil)
        #expect(
            ProviderQuota.Provider.displayOrder.count {
                $0.multiAccountCapability != nil
            } == 19
        )
    }

    @Test("Secret profiles persist without pretending to own a provider home")
    @MainActor
    func secretProfilePersistence() throws {
        let suite = "TokenRemainSecretAccounts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "tokenremain-secret-accounts-\(UUID().uuidString)")
        let store = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
        let profile = try store.prepareProfile(provider: .openrouter, displayName: "Work")

        #expect(profile.configurationDirectory == nil)
        #expect(profile.credentialKind == .keychainSecret)
        store.commit(profile)

        let restored = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
        #expect(restored.profiles == [profile])
        #expect(restored.allProfiles.contains { $0.id == .system(.openrouter) })
        #expect(restored.allProfiles.contains { $0.id == .system(.codex) })
    }

    @Test("Codex managed accounts receive a private isolated home")
    @MainActor
    func codexProfileIsolation() throws {
        let suite = "TokenRemainCodexAccounts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appending(path: "tokenremain-codex-accounts-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let store = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
        let profile = try store.prepareProfile(provider: .codex, displayName: nil)
        let directory = try #require(profile.configurationDirectory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue

        #expect(profile.credentialKind == .isolatedCLI)
        #expect(profile.displayName == "Codex 2")
        #expect(permissions & 0o077 == 0)
        store.discardPreparedProfile(profile)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test("Codex CLI discovery supports NVM installs outside a GUI app PATH")
    func codexCLIResolutionFindsNVMInstall() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "tokenremain-codex-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home
            .appending(path: ".nvm/versions/node/v24.11.0/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appending(path: "codex", directoryHint: .notDirectory)
        try Data("#!/usr/bin/env node\n".utf8).write(to: codex)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codex.path
        )

        let resolved = try #require(CodexAccountLoginService.executable(
            homeDirectory: home,
            environment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(
            resolved.resolvingSymlinksInPath().path
                == codex.resolvingSymlinksInPath().path
        )
        let launchPath = ProviderCLIExecutableResolver.launchPath(
            existing: "/usr/bin:/bin",
            executable: resolved,
            homeDirectory: home
        )
        let firstLaunchDirectory = try #require(
            launchPath.split(separator: ":").first.map(String.init)
        )
        #expect(
            URL(fileURLWithPath: firstLaunchDirectory).resolvingSymlinksInPath().path
                == bin.resolvingSymlinksInPath().path
        )
    }

    @Test("Claude CLI discovery supports NVM installs outside a GUI app PATH")
    func claudeCLIResolutionFindsNVMInstall() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "tokenremain-claude-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home
            .appending(path: ".nvm/versions/node/v22.20.0/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appending(path: "claude", directoryHint: .notDirectory)
        try Data("#!/usr/bin/env node\n".utf8).write(to: claude)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: claude.path
        )

        let resolved = try #require(ClaudeAccountLoginService.claudeExecutable(
            homeDirectory: home,
            environment: ["PATH": "/usr/bin:/bin"]
        ))
        #expect(
            resolved.resolvingSymlinksInPath().path
                == claude.resolvingSymlinksInPath().path
        )
    }

    @Test("Managed Claude environments remove inherited routing and API credentials")
    func managedClaudeEnvironmentIsolation() {
        let directory = URL(fileURLWithPath: "/tmp/tokenremain-claude-account")
        let base = [
            "ANTHROPIC_BASE_URL": "https://relay.example.com",
            "ANTHROPIC_API_KEY": "api-key",
            "ANTHROPIC_AUTH_TOKEN": "auth-token",
            "ANTHROPIC_BEDROCK_BASE_URL": "https://bedrock.example.com",
            "ANTHROPIC_VERTEX_BASE_URL": "https://vertex.example.com",
            "ANTHROPIC_FOUNDRY_BASE_URL": "https://foundry.example.com",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "CLAUDE_CODE_USE_FOUNDRY": "1",
            "PATH": "/usr/bin"
        ]

        let environment = ProviderAccountProcessEnvironment.claude(
            base: base,
            configurationDirectory: directory
        )

        #expect(environment["CLAUDE_CONFIG_DIR"] == directory.path)
        #expect(environment["PATH"] == "/usr/bin")
        for key in base.keys where key != "PATH" {
            #expect(environment[key] == nil)
        }
    }

    @Test("System Claude environment preserves the user's routing overrides")
    func systemClaudeEnvironmentPreservesOverrides() {
        let base = [
            "ANTHROPIC_BASE_URL": "https://relay.example.com",
            "ANTHROPIC_API_KEY": "api-key"
        ]

        #expect(ProviderAccountProcessEnvironment.claude(
            base: base,
            configurationDirectory: nil
        ) == base)
    }

    @Test("Managed Codex environments remove inherited routing and API credentials")
    func managedCodexEnvironmentIsolation() {
        let directory = URL(fileURLWithPath: "/tmp/tokenremain-codex-account")
        let environment = ProviderAccountProcessEnvironment.codex(
            base: [
                "OPENAI_BASE_URL": "https://relay.example.com",
                "OPENAI_API_BASE": "https://legacy-relay.example.com",
                "OPENAI_API_KEY": "api-key",
                "PATH": "/usr/bin"
            ],
            configurationDirectory: directory
        )

        #expect(environment["CODEX_HOME"] == directory.path)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["OPENAI_BASE_URL"] == nil)
        #expect(environment["OPENAI_API_BASE"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
    }

    @Test("A stale account selection is pruned instead of leaking into the UI")
    @MainActor
    func staleSelectionIsPruned() throws {
        let suite = "TokenRemainProviderAccounts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let stale = ProviderAccountSelection.account(
            .managed(UUID(uuidString: "00000000-0000-4000-8000-000000000099")!)
        )
        defaults.set(
            try JSONEncoder().encode([ProviderQuota.Provider.claude: stale]),
            forKey: ProviderAccountsStore.selectionsKey
        )

        let store = ProviderAccountsStore(
            defaults: defaults,
            rootDirectory: FileManager.default.temporaryDirectory
                .appending(path: "tokenremain-unused-\(UUID().uuidString)")
        )
        #expect(store.selection(for: .claude) == .all)
    }

    @Test("A selection cannot bind one provider card to another provider's account")
    @MainActor
    func crossProviderSelectionIsPruned() throws {
        let suite = "TokenRemainCrossProviderSelection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "tokenremain-cross-provider-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
        let codex = try first.prepareProfile(provider: .codex, displayName: "Work")
        first.commit(codex)
        defaults.set(
            try JSONEncoder().encode([
                ProviderQuota.Provider.claude: ProviderAccountSelection.account(codex.id)
            ]),
            forKey: ProviderAccountsStore.selectionsKey
        )

        let restored = ProviderAccountsStore(defaults: defaults, rootDirectory: root)
        #expect(restored.selection(for: .claude) == .all)
        #expect(restored.allProfiles.contains { $0.provider == .codex && $0.id == codex.id })
    }

    @Test("Account quota cache round-trips opaque account identifiers")
    func cacheRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tokenremain-account-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = ProviderAccountID.managed(
            UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
        )
        let cache = ProviderAccountQuotaCache(url: url)

        cache.save([id: quota(used: 18, weeklyUsed: 36)])
        let restored = cache.load()
        #expect(restored[id]?.primary.usedPercent == 18)
        #expect(restored[id]?.secondary?.usedPercent == 36)
    }

    private func snapshot(
        name: String,
        quota: ProviderQuota?,
        enabled: Bool = true
    ) -> ProviderAccountSnapshot {
        ProviderAccountSnapshot(
            profile: ProviderAccountProfile(
                id: .managed(UUID()),
                provider: .claude,
                displayName: name,
                kind: .managed,
                configurationDirectory: "/tmp/opaque-test-account",
                isEnabled: enabled,
                createdAt: .now
            ),
            state: ProviderAccountState(quota: quota)
        )
    }

    private func quota(used: Double, weeklyUsed: Double?) -> ProviderQuota {
        ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil),
            secondary: weeklyUsed.map {
                QuotaWindow(usedPercent: $0, windowMinutes: 10_080, resetsAt: nil)
            },
            planName: "Max",
            capturedAt: .now
        )
    }
}
