import Foundation
import Testing
@testable import UsageDock

@Suite("Preferences store")
@MainActor
struct PreferencesStoreTests {
    @Test("Defaults keep the historical menu bar and cadence behavior")
    func defaults() {
        let store = PreferencesStore(defaults: testDefaults())
        #expect(store.menuBarProviders == [.claude, .codex])
        #expect(store.menuBarDisplayMode == .full)
        #expect(store.popoverGlassStyle == .frosted)
        #expect(store.popoverBackgroundOpacity == PreferencesStore.defaultPopoverBackgroundOpacity)
        #expect(store.quotaSummaryStrategy == .shortestWindow)
        #expect(!store.showCodexSparkQuotaInMenuBarWidget)
        #expect(!store.showAntigravityThirdPartyQuota)
        #expect(store.refreshMinutes == 5)
        #expect(store.refreshInterval == 300)
        #expect(!store.floatingWidgetEnabled)
        #expect(!store.dockIconHidden)
    }

    @Test("Quota summary defaults to shortest window and persists alternatives")
    func quotaSummaryStrategy() {
        let defaults = testDefaults()
        PreferencesStore(defaults: defaults).setQuotaSummaryStrategy(.lowestRemaining)
        #expect(PreferencesStore(defaults: defaults).quotaSummaryStrategy == .lowestRemaining)

        defaults.set("future-strategy", forKey: PreferencesStore.quotaSummaryStrategyKey)
        #expect(PreferencesStore(defaults: defaults).quotaSummaryStrategy == .shortestWindow)
    }

    @Test("Antigravity third-party pools default off and persist")
    func antigravityThirdPartyPreference() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)
        #expect(!store.showAntigravityThirdPartyQuota)
        store.setShowAntigravityThirdPartyQuota(true)
        #expect(PreferencesStore(defaults: defaults).showAntigravityThirdPartyQuota)
    }

    @Test("Menu bar Spark quota preference defaults off and persists")
    func menuBarModelQuotaPreferences() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)
        #expect(!store.showCodexSparkQuotaInMenuBarWidget)

        store.setShowCodexSparkQuotaInMenuBarWidget(true)
        let reloaded = PreferencesStore(defaults: defaults)
        #expect(reloaded.showCodexSparkQuotaInMenuBarWidget)
    }

    @Test("Dashboard quota cards include active catalog pools by smart default")
    func dashboardModelQuotaWindows() {
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: nil),
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 70, windowMinutes: 10_080, resetsAt: nil)
                ),
                ScopedQuotaWindow(
                    scopeID: "codex_bengalfox",
                    displayName: "GPT-5.3-Codex-Spark",
                    window: QuotaWindow(usedPercent: 30, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )

        // 两个池都有用量、都没存过偏好 → 智能默认显示。
        let store = PreferencesStore(defaults: testDefaults())
        #expect(
            QuotaCard.scopedWindows(in: quota, preferences: store).map(\.scopeID)
                == ["fable", "codex_bengalfox"]
        )

        // 用户显式关掉 Fable 后,Dashboard 卡片也跟随隐藏。
        store.setScopedPoolVisibility(
            false, provider: .claude, poolKey: ScopedPoolToggleCatalog.fablePoolKey
        )
        #expect(
            QuotaCard.scopedWindows(in: quota, preferences: store).map(\.scopeID)
                == ["codex_bengalfox"]
        )
    }

    @Test("Antigravity third-party rows honor stored preference over smart default")
    func antigravityThirdPartyQuotaFilters() {
        let quota = antigravityQuota(thirdPartyUsedPercent: 25)

        let storedOff = PreferencesStore(defaults: testDefaults())
        storedOff.setScopedPoolVisibility(
            false,
            provider: .antigravity,
            poolKey: ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey
        )
        let storedOn = PreferencesStore(defaults: testDefaults())
        storedOn.setScopedPoolVisibility(
            true,
            provider: .antigravity,
            poolKey: ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey
        )

        #expect(QuotaCard.scopedWindows(in: quota, preferences: storedOff).isEmpty)
        #expect(
            QuotaCard.scopedWindows(in: quota, preferences: storedOn).map(\.scopeID)
                == ["antigravity_3p_5h"]
        )
        #expect(PopoverQuotaWidget.scopedWindows(
            in: quota,
            isExpanded: true,
            preferences: storedOff
        ).isEmpty)
        #expect(PopoverQuotaWidget.scopedWindows(
            in: quota,
            isExpanded: true,
            preferences: storedOn
        ).map(\.scopeID) == ["antigravity_3p_5h"])
    }

    @Test("Unset Antigravity third-party pools follow their own activity")
    func antigravityThirdPartySmartDefault() {
        let fresh = PreferencesStore(defaults: testDefaults())

        // 有用量 → 智能默认显示(过去的手拍默认 off 已被数据驱动取代)。
        #expect(PopoverQuotaWidget.scopedWindows(
            in: antigravityQuota(thirdPartyUsedPercent: 25),
            isExpanded: true,
            preferences: fresh
        ).map(\.scopeID) == ["antigravity_3p_5h"])
        // 从未用过 → 默认隐藏。
        #expect(PopoverQuotaWidget.scopedWindows(
            in: antigravityQuota(thirdPartyUsedPercent: 0),
            isExpanded: true,
            preferences: fresh
        ).isEmpty)
        // 3P 池仍然跟随展开态:收起时不显示。
        #expect(PopoverQuotaWidget.scopedWindows(
            in: antigravityQuota(thirdPartyUsedPercent: 25),
            isExpanded: false,
            preferences: fresh
        ).isEmpty)
    }

    @Test("Menu bar excludes Fable while Spark stays explicitly optional")
    func menuBarWidgetModelQuotaFilters() {
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 70, windowMinutes: 10_080, resetsAt: nil)
                ),
                ScopedQuotaWindow(
                    scopeID: "codex_bengalfox",
                    displayName: "GPT-5.3-Codex-Spark",
                    window: QuotaWindow(usedPercent: 50, windowMinutes: 10_080, resetsAt: nil)
                ),
                ScopedQuotaWindow(
                    scopeID: "future_model",
                    displayName: "Future Model",
                    window: QuotaWindow(usedPercent: 30, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )

        // Fable 和 Spark 一样由设置控制,都关掉时收起态不显示任何模型额度。
        let bothOff = PreferencesStore(defaults: testDefaults())
        bothOff.setShowFableQuotaInMenuBarWidget(false)
        bothOff.setShowCodexSparkQuotaInMenuBarWidget(false)
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: false,
                preferences: bothOff
            ).isEmpty
        )

        // Spark 显式开启后,收起态也显示(不跟随展开态)。
        let sparkOn = PreferencesStore(defaults: testDefaults())
        sparkOn.setShowFableQuotaInMenuBarWidget(false)
        sparkOn.setShowCodexSparkQuotaInMenuBarWidget(true)
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: false,
                preferences: sparkOn
            ).map(\.scopeID) == ["codex_bengalfox"]
        )

        // 目录外的池(future_model)不受开关影响,展开即显示。
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: true,
                preferences: bothOff
            ).map(\.scopeID) == ["future_model"]
        )
    }

    @Test("Fable follows its own setting and stays visible when collapsed")
    func fableQuotaVisibility() {
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 98, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )

        // Fable 会先于 all-models 额度耗尽,所以收起态也要看得见。
        // 没存过偏好时走智能默认:98% 已用 → 显示。
        let fresh = PreferencesStore(defaults: testDefaults())
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: false,
                preferences: fresh
            ).map(\.scopeID) == ["fable"]
        )

        let fableOff = PreferencesStore(defaults: testDefaults())
        fableOff.setShowFableQuotaInMenuBarWidget(false)
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: false,
                preferences: fableOff
            ).isEmpty
        )
    }

    @Test("Unset Fable visibility now follows usage instead of a hard default")
    func fableSmartDefault() {
        let idleFable = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 0, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )

        // 语义变化:从未用过 Fable 且没动过开关 → 默认隐藏(旧行为是
        // 无条件默认显示);动过开关后存储值永久优先。
        let fresh = PreferencesStore(defaults: testDefaults())
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: idleFable,
                isExpanded: true,
                preferences: fresh
            ).isEmpty
        )
        fresh.setShowFableQuotaInMenuBarWidget(true)
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: idleFable,
                isExpanded: false,
                preferences: fresh
            ).map(\.scopeID) == ["fable"]
        )
    }

    @Test("Paired pool windows show together and agree with the settings default")
    func pairedPoolWindowsStayConsistent() {
        // Spark 的 _session/_weekly 两行共用一个开关:时窗 0%、周窗 40% 时
        // 整组判活跃,卡片、挂件、设置开关三个消费点必须读到同一个答案。
        let quota = ProviderQuota(
            provider: .codex,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "codex_bengalfox_session",
                    displayName: "GPT-5.3-Codex-Spark",
                    window: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil)
                ),
                ScopedQuotaWindow(
                    scopeID: "codex_bengalfox_weekly",
                    displayName: "GPT-5.3-Codex-Spark",
                    window: QuotaWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )
        let sparkEntry = ScopedPoolToggleCatalog.entries.first {
            $0.poolKey == ScopedPoolToggleCatalog.codexSparkPoolKey
        }!

        let fresh = PreferencesStore(defaults: testDefaults())
        let groupActive = ScopedPoolToggleCatalog.poolIsActive(entry: sparkEntry, in: quota)
        #expect(groupActive)
        // 设置开关的智能默认(存储值为 nil 时)= 组活跃度。
        #expect(fresh.resolvedScopedPoolVisibility(
            provider: .codex,
            poolKey: sparkEntry.poolKey,
            poolIsActive: groupActive
        ))
        // 卡片与挂件都显示整组两行——旧的按行判定会把 0% 的时窗单独藏掉。
        #expect(
            QuotaCard.scopedWindows(in: quota, preferences: fresh).map(\.scopeID)
                == ["codex_bengalfox_session", "codex_bengalfox_weekly"]
        )
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: quota,
                isExpanded: false,
                preferences: fresh
            ).map(\.scopeID) == ["codex_bengalfox_session", "codex_bengalfox_weekly"]
        )

        // 存储值依旧永久优先:显式关掉后整组一起消失。
        fresh.setScopedPoolVisibility(
            false, provider: .codex, poolKey: sparkEntry.poolKey
        )
        #expect(QuotaCard.scopedWindows(in: quota, preferences: fresh).isEmpty)
        #expect(PopoverQuotaWidget.scopedWindows(
            in: quota,
            isExpanded: true,
            preferences: fresh
        ).isEmpty)
    }

    @Test("Balance-denominated pools default to visible while money remains")
    func balancePoolSmartDefault() {
        // DeepSeek 附加币种行 usedPercent 恒 0(有钱 = 0% 已用),智能默认
        // 必须看余额,否则这些池永远被判"没在用"而隐藏。
        func deepseekQuota(amount: Double) -> ProviderQuota {
            ProviderQuota(
                provider: .deepseek,
                primary: QuotaWindow(usedPercent: 10, windowMinutes: 0, resetsAt: nil),
                secondary: nil,
                planName: nil,
                capturedAt: .now,
                scopedWindows: [
                    ScopedQuotaWindow(
                        scopeID: "deepseek_CNY",
                        displayName: "CNY",
                        window: QuotaWindow(
                            usedPercent: 0,
                            windowMinutes: 0,
                            resetsAt: nil,
                            remainingBalance: QuotaBalance(amount: amount, currencyCode: "CNY")
                        )
                    )
                ]
            )
        }

        let fresh = PreferencesStore(defaults: testDefaults())
        // 余额为正 → 智能默认显示(卡片恒显;挂件里该池跟随展开态)。
        #expect(
            QuotaCard.scopedWindows(in: deepseekQuota(amount: 12.5), preferences: fresh)
                .map(\.scopeID) == ["deepseek_CNY"]
        )
        #expect(
            PopoverQuotaWidget.scopedWindows(
                in: deepseekQuota(amount: 12.5),
                isExpanded: true,
                preferences: fresh
            ).map(\.scopeID) == ["deepseek_CNY"]
        )
        // 没钱也没用量 → 依旧默认隐藏。
        #expect(
            QuotaCard.scopedWindows(in: deepseekQuota(amount: 0), preferences: fresh)
                .isEmpty
        )
    }

    @Test("Scoped pool visibility is tri-state, persists, and resolves smart defaults")
    func scopedPoolVisibilityStorage() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)

        // 从未设置 → nil,解析结果由池的活跃度决定。
        #expect(store.scopedPoolVisibility(provider: .mimo, poolKey: "mimo_daily") == nil)
        #expect(store.resolvedScopedPoolVisibility(
            provider: .mimo, poolKey: "mimo_daily", poolIsActive: true
        ))
        #expect(!store.resolvedScopedPoolVisibility(
            provider: .mimo, poolKey: "mimo_daily", poolIsActive: false
        ))

        // 存储值永久优先于活跃度。
        store.setScopedPoolVisibility(false, provider: .mimo, poolKey: "mimo_daily")
        #expect(!store.resolvedScopedPoolVisibility(
            provider: .mimo, poolKey: "mimo_daily", poolIsActive: true
        ))
        store.setScopedPoolVisibility(true, provider: .ollama, poolKey: "ollama_hourly")
        #expect(store.resolvedScopedPoolVisibility(
            provider: .ollama, poolKey: "ollama_hourly", poolIsActive: false
        ))

        // 重新加载后仍在。
        let reloaded = PreferencesStore(defaults: defaults)
        #expect(reloaded.scopedPoolVisibility(provider: .mimo, poolKey: "mimo_daily") == false)
        #expect(reloaded.scopedPoolVisibility(provider: .ollama, poolKey: "ollama_hourly") == true)
        #expect(reloaded.scopedPoolVisibility(provider: .deepseek, poolKey: "deepseek_") == nil)
    }

    @Test("Legacy toggle keys migrate once into the generic pool storage")
    func legacyPoolToggleMigration() {
        let defaults = testDefaults()
        defaults.set(false, forKey: PreferencesStore.menuBarFableQuotaKey)
        defaults.set(true, forKey: PreferencesStore.menuBarCodexSparkQuotaKey)
        // Antigravity 旧键从未存过 → 迁移后仍是 nil(智能默认接管)。

        let store = PreferencesStore(defaults: defaults)
        #expect(store.scopedPoolVisibility(
            provider: .claude, poolKey: ScopedPoolToggleCatalog.fablePoolKey
        ) == false)
        #expect(store.scopedPoolVisibility(
            provider: .codex, poolKey: ScopedPoolToggleCatalog.codexSparkPoolKey
        ) == true)
        #expect(store.scopedPoolVisibility(
            provider: .antigravity,
            poolKey: ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey
        ) == nil)

        // 迁移后新存储是唯一事实源:旧键翻转不再影响已迁移的值。
        defaults.set(true, forKey: PreferencesStore.menuBarFableQuotaKey)
        #expect(PreferencesStore(defaults: defaults).scopedPoolVisibility(
            provider: .claude, poolKey: ScopedPoolToggleCatalog.fablePoolKey
        ) == false)
    }

    @Test("Legacy toggle accessors are thin wrappers over the generic storage")
    func legacyToggleWrappers() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)

        store.setScopedPoolVisibility(
            true,
            provider: .antigravity,
            poolKey: ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey
        )
        #expect(store.showAntigravityThirdPartyQuota)

        store.setShowCodexSparkQuotaInMenuBarWidget(true)
        #expect(store.scopedPoolVisibility(
            provider: .codex, poolKey: ScopedPoolToggleCatalog.codexSparkPoolKey
        ) == true)
    }

    private func antigravityQuota(thirdPartyUsedPercent: Double) -> ProviderQuota {
        ProviderQuota(
            provider: .antigravity,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "antigravity_3p_5h",
                    displayName: "Claude / Third-party",
                    window: QuotaWindow(
                        usedPercent: thirdPartyUsedPercent,
                        windowMinutes: 300,
                        resetsAt: nil
                    )
                )
            ]
        )
    }

    @Test("Fable defaults to visible and persists an explicit opt-out")
    func fableQuotaPreferenceDefaultsOn() {
        let defaults = testDefaults()
        // 默认开启:升级上来的用户没存过这个键,不能因此看不到 Fable。
        #expect(PreferencesStore(defaults: defaults).showFableQuotaInMenuBarWidget)

        PreferencesStore(defaults: defaults).setShowFableQuotaInMenuBarWidget(false)
        #expect(!PreferencesStore(defaults: defaults).showFableQuotaInMenuBarWidget)

        PreferencesStore(defaults: defaults).setShowFableQuotaInMenuBarWidget(true)
        #expect(PreferencesStore(defaults: defaults).showFableQuotaInMenuBarWidget)
    }

    @Test("Menu bar display mode persists and rejects unknown stored values")
    func menuBarDisplayMode() {
        let defaults = testDefaults()
        PreferencesStore(defaults: defaults).setMenuBarDisplayMode(.compact)
        #expect(PreferencesStore(defaults: defaults).menuBarDisplayMode == .compact)

        defaults.set("future-mode", forKey: PreferencesStore.menuBarDisplayModeKey)
        #expect(PreferencesStore(defaults: defaults).menuBarDisplayMode == .full)
    }

    @Test("Popover background opacity persists and stays within the valid range")
    func popoverBackgroundOpacity() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)

        store.setPopoverBackgroundOpacity(0.45)
        #expect(PreferencesStore(defaults: defaults).popoverBackgroundOpacity == 0.45)

        store.setPopoverBackgroundOpacity(-1)
        #expect(store.popoverBackgroundOpacity == 0)

        store.setPopoverBackgroundOpacity(2)
        #expect(store.popoverBackgroundOpacity == 1)

        defaults.set(Double.nan, forKey: PreferencesStore.popoverBackgroundOpacityKey)
        #expect(
            PreferencesStore(defaults: defaults).popoverBackgroundOpacity
                == PreferencesStore.defaultPopoverBackgroundOpacity
        )
    }

    @Test("Dashboard background lightness defaults to the shipped dark canvas")
    func dashboardBackgroundLightnessDefault() {
        let store = PreferencesStore(defaults: testDefaults())
        #expect(store.dashboardBackgroundLightness == 0)
        #expect(
            store.dashboardBackgroundLightness
                == PreferencesStore.defaultDashboardBackgroundLightness
        )
    }

    @Test("Dashboard background lightness persists and stays within the valid range")
    func dashboardBackgroundLightness() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)

        store.setDashboardBackgroundLightness(0.4)
        #expect(PreferencesStore(defaults: defaults).dashboardBackgroundLightness == 0.4)

        store.setDashboardBackgroundLightness(-1)
        #expect(store.dashboardBackgroundLightness == 0)

        store.setDashboardBackgroundLightness(2)
        #expect(store.dashboardBackgroundLightness == 1)

        defaults.set(Double.nan, forKey: PreferencesStore.dashboardBackgroundLightnessKey)
        #expect(
            PreferencesStore(defaults: defaults).dashboardBackgroundLightness
                == PreferencesStore.defaultDashboardBackgroundLightness
        )
    }

    @Test("A stored out-of-range lightness is clamped on load, not honored")
    func dashboardBackgroundLightnessClampsStoredValue() {
        let defaults = testDefaults()
        defaults.set(4.2, forKey: PreferencesStore.dashboardBackgroundLightnessKey)
        #expect(PreferencesStore(defaults: defaults).dashboardBackgroundLightness == 1)

        defaults.set(-3.0, forKey: PreferencesStore.dashboardBackgroundLightnessKey)
        #expect(PreferencesStore(defaults: defaults).dashboardBackgroundLightness == 0)
    }

    @Test("Popover glass style defaults to frosted and persists clear glass")
    func popoverGlassStyle() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)
        #expect(store.popoverGlassStyle == .frosted)

        store.setPopoverGlassStyle(.clear)
        #expect(PreferencesStore(defaults: defaults).popoverGlassStyle == .clear)

        defaults.set("future-style", forKey: PreferencesStore.popoverGlassStyleKey)
        #expect(PreferencesStore(defaults: defaults).popoverGlassStyle == .frosted)
    }

    @Test("Menu bar selection keeps display order and persists")
    func menuBarSelection() {
        let defaults = testDefaults()
        var store = PreferencesStore(defaults: defaults)
        store.toggleMenuBar(.zai)
        store.toggleMenuBar(.cursor)
        store.toggleMenuBar(.claude)

        // 无论点选顺序如何,渲染顺序始终跟 displayOrder。
        #expect(store.menuBarProviders == [.codex, .cursor, .zai])

        store = PreferencesStore(defaults: defaults)
        #expect(store.menuBarProviders == [.codex, .cursor, .zai])
    }

    @Test("Manual-only mode yields no auto interval; invalid choices are rejected")
    func refreshChoices() {
        let defaults = testDefaults()
        let store = PreferencesStore(defaults: defaults)
        store.setRefreshMinutes(0)
        #expect(store.refreshInterval == nil)
        store.setRefreshMinutes(30)
        #expect(store.refreshInterval == 1800)
        store.setRefreshMinutes(7)
        #expect(store.refreshMinutes == 30)

        let reloaded = PreferencesStore(defaults: defaults)
        #expect(reloaded.refreshMinutes == 30)
    }

    @Test("Floating widget flag persists")
    func floatingFlag() {
        let defaults = testDefaults()
        PreferencesStore(defaults: defaults).setFloatingWidgetEnabled(true)
        #expect(PreferencesStore(defaults: defaults).floatingWidgetEnabled)
    }

    @Test("Dock icon visibility persists and maps to the native activation policy")
    func dockIconVisibility() {
        let defaults = testDefaults()
        PreferencesStore(defaults: defaults).setDockIconHidden(true)
        #expect(PreferencesStore(defaults: defaults).dockIconHidden)
        #expect(DockIconVisibility.activationPolicy(hidden: true) == .accessory)
        #expect(DockIconVisibility.activationPolicy(hidden: false) == .regular)
    }

    private func testDefaults() -> UserDefaults {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
