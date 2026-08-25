import Combine
import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case full
    case compact
    case minimal

    var id: String { rawValue }
}

enum PopoverGlassStyle: String, CaseIterable, Identifiable, Sendable {
    case frosted
    case clear

    var id: String { rawValue }
}

/// 显示与刷新的用户偏好(参考 token-monitor 的配置自由度):
/// 菜单栏显示哪些 provider、显示模式、API 直查频率、桌面浮窗开关。
/// 全部持久化在 UserDefaults,即改即生效。
@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    static let menuBarKey = "tokenRemain.menuBarProviders.v1"
    static let menuBarDisplayModeKey = "tokenRemain.menuBarDisplayMode.v1"
    static let popoverGlassStyleKey = "tokenRemain.popoverGlassStyle.v1"
    /// 逃生阀:在 macOS 26 上强制退回 legacy NSPopover。没有对应的设置项,
    /// 只在系统侧玻璃回归时给用户一条不必整版降级的自救路径。
    ///
    /// `nonisolated`:这是个不可变字符串常量,不需要 MainActor 保护,而
    /// `LiquidGlassPopupAvailability` 要从非隔离上下文读它。
    nonisolated static let forceLegacyPopoverKey = "tokenRemain.forceLegacyPopover.v1"
    static let popoverBackgroundOpacityKey = "tokenRemain.popoverBackgroundOpacity.v1"
    static let dashboardBackgroundLightnessKey = "tokenRemain.dashboardBackgroundLightness.v1"
    static let quotaSummaryStrategyKey = "tokenRemain.quotaSummaryStrategy.v1"
    /// 旧的三个手拍开关键。只在初始化时一次性迁入
    /// `scopedPoolVisibilityKey`,之后不再读写。
    static let menuBarCodexSparkQuotaKey = "tokenRemain.dashboardCodexSparkQuota.v1"
    static let menuBarFableQuotaKey = "tokenRemain.menuBarFableQuota.v1"
    static let antigravityThirdPartyQuotaKey = "tokenRemain.antigravityThirdPartyQuota.v1"
    /// 通用附加池可见性存储:单键字典 [ "<provider.rawValue>|<poolKey>": Bool ]。
    /// 键不存在 = 用户从未动过开关,由 `resolvedScopedPoolVisibility`
    /// 按"该池是否在用"给出智能默认。
    static let scopedPoolVisibilityKey = "tokenRemain.scopedPoolVisibility.v1"
    static let refreshKey = "tokenRemain.refreshMinutes.v1"
    static let floatingKey = "tokenRemain.floatingWidget.v1"
    static let dockIconHiddenKey = "tokenRemain.dockIconHidden.v1"

    static let defaultPopoverBackgroundOpacity = 0.62
    static let popoverBackgroundOpacityRange = 0.0...1.0

    /// 0 = 出厂的纯深色仪表盘。老用户升级后读到的就是这个值,观感零变化。
    static let defaultDashboardBackgroundLightness = 0.0
    static let dashboardBackgroundLightnessRange = DashboardSurfaceLightening.lightnessRange

    /// 刷新频率可选档位(分钟);0 = 仅手动刷新。
    static let refreshChoices = [1, 5, 15, 30, 0]

    /// 菜单栏文字里显示的 provider(有序子集)。默认沿用历史行为:Claude + Codex。
    @Published private(set) var menuBarProviders: [ProviderQuota.Provider]
    /// 菜单栏所选 provider 的呈现密度。默认完整显示以兼容历史行为。
    @Published private(set) var menuBarDisplayMode: MenuBarDisplayMode
    /// 菜单栏弹窗使用带雾化采样的毛玻璃，或无雾化层的透明玻璃。
    @Published private(set) var popoverGlassStyle: PopoverGlassStyle
    /// 菜单栏弹窗深色底衬的不透明度；卡片与文字不受影响。
    @Published private(set) var popoverBackgroundOpacity: Double
    /// 仪表盘背景的整体明度；0 = 纯深色,1 = 最浅的冷灰底。
    /// 只影响仪表盘的底色/卡片/描边,文字与弹窗都不跟着走。
    @Published private(set) var dashboardBackgroundLightness: Double
    /// Which account-level window compact summary surfaces display.
    @Published private(set) var quotaSummaryStrategy: QuotaSummaryStrategy
    /// 附加池可见性 tri-state 存储(键见 `scopedPoolStorageKey`)。
    /// @Published 让任何池开关变化都能驱动挂件/卡片刷新。
    @Published private(set) var scopedPoolVisibilityByKey: [String: Bool]
    /// Claude 与各直查 provider 的自动刷新间隔(分钟);0 = 仅手动。
    @Published private(set) var refreshMinutes: Int
    /// 桌面浮窗(置顶的挂件面板)。
    @Published private(set) var floatingWidgetEnabled: Bool
    /// 隐藏 Dock 与应用切换器里的应用图标；菜单栏入口保持可用。
    @Published private(set) var dockIconHidden: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Self.menuBarKey) as? [String] {
            menuBarProviders = raw.compactMap(ProviderQuota.Provider.init(rawValue:))
        } else {
            menuBarProviders = [.claude, .codex]
        }
        menuBarDisplayMode = defaults.string(forKey: Self.menuBarDisplayModeKey)
            .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .full
        popoverGlassStyle = defaults.string(forKey: Self.popoverGlassStyleKey)
            .flatMap(PopoverGlassStyle.init(rawValue:)) ?? .frosted
        let storedPopoverOpacity = defaults.object(forKey: Self.popoverBackgroundOpacityKey) as? Double
        popoverBackgroundOpacity = Self.clampedPopoverBackgroundOpacity(
            storedPopoverOpacity ?? Self.defaultPopoverBackgroundOpacity
        )
        let storedDashboardLightness = defaults
            .object(forKey: Self.dashboardBackgroundLightnessKey) as? Double
        dashboardBackgroundLightness = Self.clampedDashboardBackgroundLightness(
            storedDashboardLightness ?? Self.defaultDashboardBackgroundLightness
        )
        quotaSummaryStrategy = defaults.string(forKey: Self.quotaSummaryStrategyKey)
            .flatMap(QuotaSummaryStrategy.init(rawValue:)) ?? .shortestWindow
        scopedPoolVisibilityByKey = Self.loadScopedPoolVisibility(migratingFrom: defaults)
        let storedMinutes = defaults.object(forKey: Self.refreshKey) as? Int
        refreshMinutes = storedMinutes.map { Self.refreshChoices.contains($0) ? $0 : 5 } ?? 5
        floatingWidgetEnabled = defaults.bool(forKey: Self.floatingKey)
        dockIconHidden = defaults.bool(forKey: Self.dockIconHiddenKey)
    }

    func isInMenuBar(_ provider: ProviderQuota.Provider) -> Bool {
        menuBarProviders.contains(provider)
    }

    /// 切换某 provider 是否出现在菜单栏,顺序保持 displayOrder。
    func toggleMenuBar(_ provider: ProviderQuota.Provider) {
        var set = Set(menuBarProviders)
        if set.contains(provider) {
            set.remove(provider)
        } else {
            set.insert(provider)
        }
        menuBarProviders = ProviderQuota.Provider.displayOrder.filter(set.contains)
        defaults.set(menuBarProviders.map(\.rawValue), forKey: Self.menuBarKey)
    }

    func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) {
        menuBarDisplayMode = mode
        defaults.set(mode.rawValue, forKey: Self.menuBarDisplayModeKey)
    }

    func setPopoverGlassStyle(_ style: PopoverGlassStyle) {
        popoverGlassStyle = style
        defaults.set(style.rawValue, forKey: Self.popoverGlassStyleKey)
    }

    func setPopoverBackgroundOpacity(_ opacity: Double) {
        let clamped = Self.clampedPopoverBackgroundOpacity(opacity)
        popoverBackgroundOpacity = clamped
        defaults.set(clamped, forKey: Self.popoverBackgroundOpacityKey)
    }

    func setDashboardBackgroundLightness(_ lightness: Double) {
        let clamped = Self.clampedDashboardBackgroundLightness(lightness)
        dashboardBackgroundLightness = clamped
        defaults.set(clamped, forKey: Self.dashboardBackgroundLightnessKey)
    }

    func setQuotaSummaryStrategy(_ strategy: QuotaSummaryStrategy) {
        quotaSummaryStrategy = strategy
        defaults.set(strategy.rawValue, forKey: Self.quotaSummaryStrategyKey)
    }

    // MARK: - 附加池可见性(通用 tri-state 存储 + 智能默认)

    /// 用户对某个池组的显式选择;nil = 从未设置过。
    func scopedPoolVisibility(
        provider: ProviderQuota.Provider,
        poolKey: String
    ) -> Bool? {
        scopedPoolVisibilityByKey[Self.scopedPoolStorageKey(provider: provider, poolKey: poolKey)]
    }

    func setScopedPoolVisibility(
        _ visible: Bool,
        provider: ProviderQuota.Provider,
        poolKey: String
    ) {
        scopedPoolVisibilityByKey[
            Self.scopedPoolStorageKey(provider: provider, poolKey: poolKey)
        ] = visible
        defaults.set(scopedPoolVisibilityByKey, forKey: Self.scopedPoolVisibilityKey)
    }

    /// 智能默认解析(方案"统一原则"第 3 条):用户动过开关后存储值永久
    /// 优先;从未动过时按"该池是否在用"决定——有过非零用量默认显示,
    /// 从未用过默认隐藏。`poolIsActive` 由调用方从窗口数据算
    /// (通常是 `usedPercent > 0`)。
    func resolvedScopedPoolVisibility(
        provider: ProviderQuota.Provider,
        poolKey: String,
        poolIsActive: Bool
    ) -> Bool {
        scopedPoolVisibility(provider: provider, poolKey: poolKey) ?? poolIsActive
    }

    static func scopedPoolStorageKey(
        provider: ProviderQuota.Provider,
        poolKey: String
    ) -> String {
        "\(provider.rawValue)|\(poolKey)"
    }

    /// 读出通用存储,并把三个旧布尔键(存在才算,`defaults.bool` 会把
    /// "没存过"当 false)一次性迁入。旧键保留不删,方便降级回旧版本。
    private static func loadScopedPoolVisibility(
        migratingFrom defaults: UserDefaults
    ) -> [String: Bool] {
        var stored = defaults.dictionary(forKey: scopedPoolVisibilityKey)?
            .compactMapValues { $0 as? Bool } ?? [:]
        let legacyMappings: [(legacyKey: String, provider: ProviderQuota.Provider, poolKey: String)] = [
            (menuBarFableQuotaKey, .claude, ScopedPoolToggleCatalog.fablePoolKey),
            (menuBarCodexSparkQuotaKey, .codex, ScopedPoolToggleCatalog.codexSparkPoolKey),
            (antigravityThirdPartyQuotaKey, .antigravity,
             ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey)
        ]
        var migrated = false
        for mapping in legacyMappings {
            let storageKey = scopedPoolStorageKey(
                provider: mapping.provider,
                poolKey: mapping.poolKey
            )
            guard stored[storageKey] == nil,
                  let legacyValue = defaults.object(forKey: mapping.legacyKey) as? Bool else {
                continue
            }
            stored[storageKey] = legacyValue
            migrated = true
        }
        if migrated {
            defaults.set(stored, forKey: scopedPoolVisibilityKey)
        }
        return stored
    }

    // MARK: - 旧三开关的薄封装(向后兼容)

    /// **语义变化**:挂件/卡片的过滤已改走 `resolvedScopedPoolVisibility`
    /// ——没存过键时,Fable 只有在有用量时才默认显示(智能默认),不再
    /// 无条件默认 true。这个旧访问器只服务缺少窗口数据的调用方(设置页
    /// 开关的未设置态),保留历史 `?? true` 兜底以免开关显示为关、挂件
    /// 却在显示的错位。
    var showFableQuotaInMenuBarWidget: Bool {
        scopedPoolVisibility(
            provider: .claude,
            poolKey: ScopedPoolToggleCatalog.fablePoolKey
        ) ?? true
    }

    /// 未设置态沿用历史默认 false;实际显示走智能默认(有用量即显示)。
    var showCodexSparkQuotaInMenuBarWidget: Bool {
        scopedPoolVisibility(
            provider: .codex,
            poolKey: ScopedPoolToggleCatalog.codexSparkPoolKey
        ) ?? false
    }

    /// 未设置态沿用历史默认 false;实际显示走智能默认(有用量即显示)。
    var showAntigravityThirdPartyQuota: Bool {
        scopedPoolVisibility(
            provider: .antigravity,
            poolKey: ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey
        ) ?? false
    }

    func setShowCodexSparkQuotaInMenuBarWidget(_ enabled: Bool) {
        setScopedPoolVisibility(
            enabled,
            provider: .codex,
            poolKey: ScopedPoolToggleCatalog.codexSparkPoolKey
        )
    }

    func setShowFableQuotaInMenuBarWidget(_ enabled: Bool) {
        setScopedPoolVisibility(
            enabled,
            provider: .claude,
            poolKey: ScopedPoolToggleCatalog.fablePoolKey
        )
    }

    func setShowAntigravityThirdPartyQuota(_ enabled: Bool) {
        setScopedPoolVisibility(
            enabled,
            provider: .antigravity,
            poolKey: ScopedPoolToggleCatalog.antigravityThirdPartyPoolKey
        )
    }

    func setRefreshMinutes(_ minutes: Int) {
        guard Self.refreshChoices.contains(minutes) else { return }
        refreshMinutes = minutes
        defaults.set(minutes, forKey: Self.refreshKey)
    }

    func setFloatingWidgetEnabled(_ enabled: Bool) {
        floatingWidgetEnabled = enabled
        defaults.set(enabled, forKey: Self.floatingKey)
    }

    func setDockIconHidden(_ hidden: Bool) {
        dockIconHidden = hidden
        defaults.set(hidden, forKey: Self.dockIconHiddenKey)
    }

    /// 自动刷新间隔(秒);仅手动模式返回 nil。
    var refreshInterval: TimeInterval? {
        refreshMinutes > 0 ? TimeInterval(refreshMinutes * 60) : nil
    }

    private static func clampedPopoverBackgroundOpacity(_ opacity: Double) -> Double {
        guard opacity.isFinite else { return defaultPopoverBackgroundOpacity }
        return min(max(opacity, popoverBackgroundOpacityRange.lowerBound),
                   popoverBackgroundOpacityRange.upperBound)
    }

    /// 非有限值一律退回默认(=0 现状),不让一条脏的 defaults 把整个仪表盘
    /// 洗成灰的。
    private static func clampedDashboardBackgroundLightness(_ lightness: Double) -> Double {
        guard lightness.isFinite else { return defaultDashboardBackgroundLightness }
        return min(max(lightness, dashboardBackgroundLightnessRange.lowerBound),
                   dashboardBackgroundLightnessRange.upperBound)
    }
}
