import Foundation
import Testing
@testable import UsageDock

@Suite("Scoped pool toggle catalog")
struct ScopedPoolToggleCatalogTests {
    private func scoped(
        _ scopeID: String,
        _ displayName: String,
        usedPercent: Double = 10,
        remainingBalance: QuotaBalance? = nil
    ) -> ScopedQuotaWindow {
        ScopedQuotaWindow(
            scopeID: scopeID,
            displayName: displayName,
            window: QuotaWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                remainingBalance: remainingBalance
            )
        )
    }

    private func quota(
        provider: ProviderQuota.Provider,
        scopedWindows: [ScopedQuotaWindow]
    ) -> ProviderQuota {
        ProviderQuota(
            provider: provider,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: scopedWindows
        )
    }

    private func entry(forPoolKey poolKey: String) -> ScopedPoolToggleCatalog.Entry {
        ScopedPoolToggleCatalog.entries.first { $0.poolKey == poolKey }!
    }

    @Test("Catalog pools classify by scope-ID prefix")
    func classifiesCatalogPools() {
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("fable", "Fable"), provider: .claude
        ) == ScopedPoolToggleCatalog.fablePoolKey)
        // Codex 模型池成对携带 _session/_weekly 后缀,共用同一个开关。
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("codex_bengalfox_session", "GPT-5.3-Codex-Spark"), provider: .codex
        ) == ScopedPoolToggleCatalog.codexSparkPoolKey)
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("codex_bengalfox_weekly", "GPT-5.3-Codex-Spark"), provider: .codex
        ) == ScopedPoolToggleCatalog.codexSparkPoolKey)
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("antigravity_3p_5h", "Claude / Third-party"), provider: .antigravity
        ) == ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey)
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("antigravity_3p_weekly", "Claude / Third-party"), provider: .antigravity
        ) == ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey)
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("mimo_daily", "Daily"), provider: .mimo
        ) == "mimo_daily")
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("ollama_hourly", "Hourly"), provider: .ollama
        ) == "ollama_hourly")
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("deepseek_CNY", "CNY"), provider: .deepseek
        ) == "deepseek_")
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("openrouter_credits", "Credits"), provider: .openrouter
        ) == "openrouter_credits")
    }

    @Test("Account-level sibling pools stay outside the catalog")
    func accountLevelPoolsAreNotToggleable() {
        // 这些是账户主额度的组成部分,藏掉任何一个都会掩盖真实瓶颈,
        // 所以永不进目录、不做开关。
        let accountLevelScopes: [(String, String, ProviderQuota.Provider)] = [
            ("cursor_auto", "Cursor Models", .cursor),
            ("cursor_api", "Other Models", .cursor),
            ("copilot_chat", "Chat", .copilot),
            ("copilot_completions", "Completions", .copilot),
            ("qoder_personal", "Personal", .qoder),
            ("qoder_shared", "Shared", .qoder),
            ("kimi_daily", "Daily", .kimi),
            ("zai_mcp_monthly", "MCP", .zai),
            ("zcode_glm_5_2", "GLM-5.2", .zai),
            ("ollama_weekly", "Weekly", .ollama)
        ]
        for (scopeID, displayName, provider) in accountLevelScopes {
            #expect(
                ScopedPoolToggleCatalog.poolKey(
                    for: scoped(scopeID, displayName),
                    provider: provider
                ) == nil,
                "\(scopeID) must not be toggleable"
            )
        }
    }

    @Test("Display-name fallbacks keep legacy Fable and Spark rows classified")
    func displayNameFallbacks() {
        // PTY 兜底解析可能给出非常规 scopeID;显示名仍能确定池归属
        // (对齐旧 isFable / isCodexSpark 的判定)。
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("model_a", "Fable"), provider: .claude
        ) == ScopedPoolToggleCatalog.fablePoolKey)
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("model_b", "GPT-5.3-Codex-Spark"), provider: .codex
        ) == ScopedPoolToggleCatalog.codexSparkPoolKey)
        // re-hosted 快照:宿主 provider 不同也能按 scope 前缀归类。
        #expect(ScopedPoolToggleCatalog.poolKey(
            for: scoped("codex_bengalfox_weekly", "GPT-5.3-Codex-Spark"), provider: .claude
        ) == ScopedPoolToggleCatalog.codexSparkPoolKey)
    }

    @Test("Per-provider listing groups entries for the settings page")
    func perProviderListing() {
        #expect(ScopedPoolToggleCatalog.entries(for: .claude).map(\.poolKey) == ["fable"])
        #expect(ScopedPoolToggleCatalog.entries(for: .cursor).isEmpty)
        // 每条目录项都要有稳定唯一的 id 与 L10n 键,供设置页直接渲染。
        let ids = ScopedPoolToggleCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ScopedPoolToggleCatalog.entries.allSatisfy {
            !$0.titleKey.isEmpty && !$0.detailKey.isEmpty
        })
    }

    @Test("Settings sections only render for connected apps with pools")
    func settingsGroupsSkipUnconnectedAndPoollessApps() {
        let order: [ProviderQuota.Provider] = [.codex, .cursor, .claude, .mimo, .openrouter]
        let connected: Set<ProviderQuota.Provider> = [.codex, .cursor, .claude, .mimo]
        let groups = ScopedPoolToggleCatalog.settingsGroups(
            order: order,
            isConnected: { connected.contains($0) }
        )
        // Cursor 没有可开关的池;OpenRouter 有池但没接入 —— 两者都不成节。
        // 顺序沿用调用方给的追踪顺序。
        #expect(groups.map(\.provider) == [.codex, .claude, .mimo])
        #expect(groups.map { $0.entries.map(\.poolKey) } == [
            [ScopedPoolToggleCatalog.codexSparkPoolKey],
            [ScopedPoolToggleCatalog.fablePoolKey],
            ["mimo_daily"]
        ])
    }

    @Test("Settings sections drop duplicates and render nothing when unconnected")
    func settingsGroupsDedupeAndEmptyState() {
        #expect(ScopedPoolToggleCatalog.settingsGroups(
            order: ScopedPoolToggleCatalog.entries.map(\.provider),
            isConnected: { _ in false }
        ).isEmpty)
        let duplicated = ScopedPoolToggleCatalog.settingsGroups(
            order: [.claude, .claude],
            isConnected: { _ in true }
        )
        #expect(duplicated.map(\.provider) == [.claude])
    }

    @Test("Only Fable defaults to visible when no window data is available")
    func visibilityFallbackWithoutData() {
        let visibleWithoutData = ScopedPoolToggleCatalog.entries
            .filter(\.visibilityFallbackWithoutData)
            .map(\.poolKey)
        #expect(visibleWithoutData == [ScopedPoolToggleCatalog.fablePoolKey])
    }

    @Test("Pool activity is judged over the whole pool group, not per row")
    func poolGroupActivity() {
        let spark = entry(forPoolKey: ScopedPoolToggleCatalog.codexSparkPoolKey)

        // 时窗还没用、周窗用过:整组判活跃 → session/weekly 两行显隐一致,
        // 不再出现"周窗显示、时窗隐藏"的割裂。
        let oneRowActive = quota(provider: .codex, scopedWindows: [
            scoped("codex_bengalfox_session", "GPT-5.3-Codex-Spark", usedPercent: 0),
            scoped("codex_bengalfox_weekly", "GPT-5.3-Codex-Spark", usedPercent: 40)
        ])
        #expect(ScopedPoolToggleCatalog.poolIsActive(entry: spark, in: oneRowActive))

        // 两行都没用 → 整组闲置。
        let idle = quota(provider: .codex, scopedWindows: [
            scoped("codex_bengalfox_session", "GPT-5.3-Codex-Spark", usedPercent: 0),
            scoped("codex_bengalfox_weekly", "GPT-5.3-Codex-Spark", usedPercent: 0)
        ])
        #expect(!ScopedPoolToggleCatalog.poolIsActive(entry: spark, in: idle))

        // 目录外的活跃行(future_model)不能替本组作证。
        let otherRowActive = quota(provider: .codex, scopedWindows: [
            scoped("codex_bengalfox_session", "GPT-5.3-Codex-Spark", usedPercent: 0),
            scoped("future_model", "Future Model", usedPercent: 80)
        ])
        #expect(!ScopedPoolToggleCatalog.poolIsActive(entry: spark, in: otherRowActive))

        // 该池在此份额度里根本没有窗口 → 不活跃(设置页对这种情况另走
        // visibilityFallbackWithoutData 的保守默认)。
        let fable = entry(forPoolKey: ScopedPoolToggleCatalog.fablePoolKey)
        #expect(!ScopedPoolToggleCatalog.poolIsActive(entry: fable, in: oneRowActive))
    }

    @Test("Balance-denominated pools count a positive balance as active")
    func balancePoolActivity() {
        let deepseek = entry(forPoolKey: "deepseek_")

        // 余额型池 usedPercent 恒为 0(有钱 = 0% 已用):正余额必须算
        // "在用",否则智能默认永远隐藏一个明明有钱的池。
        let funded = quota(provider: .deepseek, scopedWindows: [
            scoped(
                "deepseek_CNY", "CNY",
                usedPercent: 0,
                remainingBalance: QuotaBalance(amount: 12.5, currencyCode: "CNY")
            )
        ])
        #expect(ScopedPoolToggleCatalog.poolIsActive(entry: deepseek, in: funded))

        // 组判定同样适用:任一币种有钱即整组活跃(零余额的行跟着显示)。
        let partiallyFunded = quota(provider: .deepseek, scopedWindows: [
            scoped(
                "deepseek_USD", "USD",
                usedPercent: 0,
                remainingBalance: QuotaBalance(amount: 0, currencyCode: "USD")
            ),
            scoped(
                "deepseek_CNY", "CNY",
                usedPercent: 0,
                remainingBalance: QuotaBalance(amount: 3, currencyCode: "CNY")
            )
        ])
        #expect(ScopedPoolToggleCatalog.poolIsActive(entry: deepseek, in: partiallyFunded))

        // 没钱也没用量 → 闲置;余额缺失(nil)不算有钱。
        let drained = quota(provider: .deepseek, scopedWindows: [
            scoped(
                "deepseek_CNY", "CNY",
                usedPercent: 0,
                remainingBalance: QuotaBalance(amount: 0, currencyCode: "CNY")
            ),
            scoped("deepseek_USD", "USD", usedPercent: 0)
        ])
        #expect(!ScopedPoolToggleCatalog.poolIsActive(entry: deepseek, in: drained))
    }

    @Test("Fable and Spark ignore the collapsed state; other pools follow it")
    func followsExpansionFlags() {
        let ignoresExpansion = ScopedPoolToggleCatalog.entries
            .filter { !$0.followsExpansion }
            .map(\.poolKey)
        #expect(ignoresExpansion == [
            ScopedPoolToggleCatalog.fablePoolKey,
            ScopedPoolToggleCatalog.codexSparkPoolKey
        ])
    }
}
