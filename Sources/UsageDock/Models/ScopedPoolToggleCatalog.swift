import Foundation

/// 可开关的附加额度池静态目录(见 reports/provider-quota-pool-fix-plan-2026-08-24.md
/// "统一原则"第 3 条)。目录只收"模型级 / 附加池"——用户可以选择显不显示、
/// 隐藏后主额度语义仍完整的那几行:Fable、Codex Spark、Antigravity 3P、
/// MiMo 日池、Ollama 小时池、DeepSeek 多币种、OpenRouter 积分池。
///
/// **账户级兄弟池永不进目录**:Cursor cursor_auto/cursor_api、Copilot
/// copilot_chat/copilot_completions、Qoder qoder_personal/qoder_shared、
/// ZCode 模型池、Kimi/Z.ai 的中间时长档都是账户主额度的组成部分,藏掉任何
/// 一个都会掩盖真实瓶颈,所以始终跟随展开态显示,不提供开关。
///
/// 设置页(下一批重构)按 `entries(for:)` 渲染 per-app 开关组;
/// 挂件/卡片按 `entry(for:provider:)` 归类后走
/// `PreferencesStore.resolvedScopedPoolVisibility` 的智能默认。
enum ScopedPoolToggleCatalog {
    struct Entry: Sendable, Equatable, Identifiable {
        let provider: ProviderQuota.Provider
        /// scopeID 前缀(小写)。一个池组可能有多条 scoped 窗口
        /// (如 codex_bengalfox_session / _weekly),共用同一个开关。
        let poolKey: String
        /// 设置页开关标题的 L10n 键。
        let titleKey: String
        /// 设置页开关描述的 L10n 键。
        let detailKey: String
        /// 弹窗收起态是否隐藏该池(true = 跟随展开态)。Fable 与 Spark
        /// 历史上不跟随展开:Fable 往往先于 all-models 额度耗尽,收起态
        /// 藏掉它等于藏掉真正的瓶颈;Spark 沿用既有语义(用户显式开启
        /// 就是要在收起态看到)。
        let followsExpansion: Bool

        var id: String { "\(provider.rawValue)|\(poolKey)" }

        /// 设置页开关在"用户没动过 + 也拿不到窗口数据"时显示的保守默认,
        /// 与旧版三个独立开关的历史默认一致(Fable 显示,其余隐藏)。
        /// 有窗口数据时一律走 `resolvedScopedPoolVisibility` 的智能默认。
        var visibilityFallbackWithoutData: Bool {
            poolKey == ScopedPoolToggleCatalog.fablePoolKey
        }
    }

    /// 设置页的一节:一个应用 + 它自己的池开关。
    struct ProviderGroup: Sendable, Equatable, Identifiable {
        let provider: ProviderQuota.Provider
        let entries: [Entry]

        var id: String { provider.rawValue }
    }

    /// 三个历史开关对应的池键。也是旧 UserDefaults 布尔键迁移到
    /// 通用存储时使用的键(见 PreferencesStore)。
    static let fablePoolKey = "fable"
    static let codexSparkPoolKey = "codex_bengalfox"
    static let antigravityThirdPartyPoolKey = "antigravity_3p_"

    static let entries: [Entry] = [
        Entry(
            provider: .claude,
            poolKey: fablePoolKey,
            titleKey: "settings.menubar_fable",
            detailKey: "settings.menubar_fable_hint",
            followsExpansion: false
        ),
        Entry(
            provider: .codex,
            poolKey: codexSparkPoolKey,
            titleKey: "settings.menubar_codex_spark",
            detailKey: "settings.menubar_codex_spark_hint",
            followsExpansion: false
        ),
        Entry(
            provider: .antigravity,
            poolKey: antigravityThirdPartyPoolKey,
            titleKey: "settings.antigravity_3p",
            detailKey: "settings.antigravity_3p_hint",
            followsExpansion: true
        ),
        Entry(
            provider: .mimo,
            poolKey: "mimo_daily",
            titleKey: "settings.pool_mimo_daily",
            detailKey: "settings.pool_mimo_daily_hint",
            followsExpansion: true
        ),
        Entry(
            provider: .ollama,
            poolKey: "ollama_hourly",
            titleKey: "settings.pool_ollama_hourly",
            detailKey: "settings.pool_ollama_hourly_hint",
            followsExpansion: true
        ),
        Entry(
            provider: .deepseek,
            poolKey: "deepseek_",
            titleKey: "settings.pool_deepseek_currencies",
            detailKey: "settings.pool_deepseek_currencies_hint",
            followsExpansion: true
        ),
        Entry(
            provider: .openrouter,
            poolKey: "openrouter_credits",
            titleKey: "settings.pool_openrouter_credits",
            detailKey: "settings.pool_openrouter_credits_hint",
            followsExpansion: true
        )
    ]

    /// 设置页 per-app 分组渲染用。
    static func entries(for provider: ProviderQuota.Provider) -> [Entry] {
        entries.filter { $0.provider == provider }
    }

    /// 设置页按应用分节的数据源。原则是"在用才醒目":只有目录里有条目、
    /// 且当前确实接入(有额度数据)的应用才成节,没接入的整节不渲染,
    /// 免得设置页被 7 类池开关撑长。顺序由调用方给(通常是用户在
    /// TrackedProvidersStore 里的排序),这里只做过滤。
    static func settingsGroups(
        order: [ProviderQuota.Provider],
        isConnected: (ProviderQuota.Provider) -> Bool
    ) -> [ProviderGroup] {
        var seen = Set<ProviderQuota.Provider>()
        return order.compactMap { provider in
            guard seen.insert(provider).inserted else { return nil }
            let poolEntries = entries(for: provider)
            guard !poolEntries.isEmpty, isConnected(provider) else { return nil }
            return ProviderGroup(provider: provider, entries: poolEntries)
        }
    }

    /// 把一条 scoped 窗口归类到目录里的池组;不在目录中(账户级兄弟池等)
    /// 返回 nil,由调用方沿用"跟随展开态 / dashboard 恒显"的既有行为。
    static func poolKey(
        for scoped: ScopedQuotaWindow,
        provider: ProviderQuota.Provider
    ) -> String? {
        entry(for: scoped, provider: provider)?.poolKey
    }

    /// 池组当前是否"在用"——挂件/卡片的过滤与设置页开关的智能默认必须
    /// 共用这一份判定,否则同一 poolKey 组的多条 scoped 行(如 Codex Spark
    /// 的 codex_bengalfox_session / _weekly)会各算各的,出现"周窗显示、
    /// 时窗隐藏、开关显示关"的割裂。判定对组内**所有**行取或:任一行
    /// 满足即整组活跃,`resolvedScopedPoolVisibility` 的智能默认随之对
    /// 整组一致。
    ///
    /// 单行的"在用"语义有两种形态:
    /// - 用量型池:usedPercent > 0(用过才算在用);
    /// - 余额型池(DeepSeek 附加币种等):usedPercent 恒为 0——"有钱"
    ///   就是 0% 已用,只看用量会把余额为正的池永远判成闲置而隐藏,
    ///   所以正余额同样算"在用"。
    static func poolIsActive(entry: Entry, in quota: ProviderQuota) -> Bool {
        quota.uniqueScopedWindows.contains { scoped in
            self.entry(for: scoped, provider: quota.provider)?.id == entry.id
                && windowIsActive(scoped.window)
        }
    }

    /// 单行判定;组语义(任一行为真即整组为真)在 `poolIsActive(entry:in:)`。
    private static func windowIsActive(_ window: QuotaWindow) -> Bool {
        window.usedPercent > 0 || (window.remainingBalance?.amount ?? 0) > 0
    }

    static func entry(
        for scoped: ScopedQuotaWindow,
        provider: ProviderQuota.Provider
    ) -> Entry? {
        let scope = scoped.scopeID.lowercased()
        if let match = entries.first(where: {
            $0.provider == provider && scope.hasPrefix($0.poolKey)
        }) {
            return match
        }
        // 跨宿主兜底:re-hosted 快照或混合来源里,scope 前缀依然能唯一确定
        // 池组——旧的 isFable / isCodexSpark 判定同样不看宿主 provider。
        // 可见性键始终用 entry.provider(池的归属方),与宿主无关。
        if let match = entries.first(where: { scope.hasPrefix($0.poolKey) }) {
            return match
        }
        // 兼容 `isFable` / `isCodexSpark` 的 displayName 兜底:PTY 兜底解析
        // 可能给出非常规 scopeID,但显示名仍能确定池归属。
        if scoped.isFable {
            return entries.first { $0.poolKey == fablePoolKey }
        }
        if scoped.isCodexSpark {
            return entries.first { $0.poolKey == codexSparkPoolKey }
        }
        return nil
    }
}
