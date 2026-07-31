import Combine
import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case full
    case compact
    case minimal

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
    static let dashboardFableQuotaKey = "tokenRemain.dashboardFableQuota.v1"
    static let dashboardCodexSparkQuotaKey = "tokenRemain.dashboardCodexSparkQuota.v1"
    static let refreshKey = "tokenRemain.refreshMinutes.v1"
    static let floatingKey = "tokenRemain.floatingWidget.v1"

    /// 刷新频率可选档位(分钟);0 = 仅手动刷新。
    static let refreshChoices = [1, 5, 15, 30, 0]

    /// 菜单栏文字里显示的 provider(有序子集)。默认沿用历史行为:Claude + Codex。
    @Published private(set) var menuBarProviders: [ProviderQuota.Provider]
    /// 菜单栏所选 provider 的呈现密度。默认完整显示以兼容历史行为。
    @Published private(set) var menuBarDisplayMode: MenuBarDisplayMode
    /// Dashboard Claude 额度卡是否显示 Fable 独立额度；默认关闭。
    @Published private(set) var showFableQuotaInDashboard: Bool
    /// Dashboard Codex 额度卡是否显示 GPT-5.3-Codex-Spark 独立额度；默认关闭。
    @Published private(set) var showCodexSparkQuotaInDashboard: Bool
    /// Claude 与各直查 provider 的自动刷新间隔(分钟);0 = 仅手动。
    @Published private(set) var refreshMinutes: Int
    /// 桌面浮窗(置顶的挂件面板)。
    @Published private(set) var floatingWidgetEnabled: Bool

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
        showFableQuotaInDashboard = defaults.bool(forKey: Self.dashboardFableQuotaKey)
        showCodexSparkQuotaInDashboard = defaults.bool(forKey: Self.dashboardCodexSparkQuotaKey)
        let storedMinutes = defaults.object(forKey: Self.refreshKey) as? Int
        refreshMinutes = storedMinutes.map { Self.refreshChoices.contains($0) ? $0 : 5 } ?? 5
        floatingWidgetEnabled = defaults.bool(forKey: Self.floatingKey)
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

    func setShowFableQuotaInDashboard(_ enabled: Bool) {
        showFableQuotaInDashboard = enabled
        defaults.set(enabled, forKey: Self.dashboardFableQuotaKey)
    }

    func setShowCodexSparkQuotaInDashboard(_ enabled: Bool) {
        showCodexSparkQuotaInDashboard = enabled
        defaults.set(enabled, forKey: Self.dashboardCodexSparkQuotaKey)
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

    /// 自动刷新间隔(秒);仅手动模式返回 nil。
    var refreshInterval: TimeInterval? {
        refreshMinutes > 0 ? TimeInterval(refreshMinutes * 60) : nil
    }
}
