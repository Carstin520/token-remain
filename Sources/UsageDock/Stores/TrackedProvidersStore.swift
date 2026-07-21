import Combine
import Foundation

/// 用户选择追踪哪些 provider:onboarding 的确认结果 + 额度页的后续增删,
/// 都落在这一份持久化集合上。未做过选择(含老版本升级)默认全部追踪,
/// 行为与历史版本一致。
@MainActor
final class TrackedProvidersStore: ObservableObject {
    static let shared = TrackedProvidersStore()

    static let enabledKey = "tokenRemain.trackedProviders.v1"
    static let onboardingKey = "tokenRemain.onboardingCompleted.v1"
    static let orderKey = "tokenRemain.trackedProvidersOrder.v1"

    /// UI 展示与遍历用的稳定顺序。
    static let allProviders = ProviderQuota.Provider.displayOrder

    @Published private(set) var enabled: Set<ProviderQuota.Provider>
    @Published private(set) var order: [ProviderQuota.Provider]
    @Published private(set) var hasCompletedOnboarding: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // QA 钩子:`--reset-onboarding` 启动参数重看首启引导,
        // 与其他 launch-preview 标记同风格。
        if ProcessInfo.processInfo.arguments.contains("--reset-onboarding") {
            defaults.removeObject(forKey: Self.onboardingKey)
        }
        hasCompletedOnboarding = defaults.bool(forKey: Self.onboardingKey)
        if let raw = defaults.array(forKey: Self.enabledKey) as? [String] {
            enabled = Set(raw.compactMap(ProviderQuota.Provider.init(rawValue:)))
        } else {
            enabled = Set(Self.allProviders)
        }
        let savedOrder = (defaults.array(forKey: Self.orderKey) as? [String]) ?? []
        order = Self.mergedOrder(savedOrder)
    }

    /// enabled 中按稳定顺序排列的 provider 列表。
    var enabledOrdered: [ProviderQuota.Provider] {
        order.filter(enabled.contains)
    }

    var disabledOrdered: [ProviderQuota.Provider] {
        order.filter { !enabled.contains($0) }
    }

    func isEnabled(_ provider: ProviderQuota.Provider) -> Bool {
        enabled.contains(provider)
    }

    func setEnabled(_ provider: ProviderQuota.Provider, _ isOn: Bool) {
        if isOn {
            enabled.insert(provider)
        } else {
            enabled.remove(provider)
        }
        persistEnabled()
    }

    /// Moves a provider card ahead of another provider and persists the full
    /// order so hiding/showing a card never discards the user's arrangement.
    func move(_ provider: ProviderQuota.Provider, before destination: ProviderQuota.Provider) {
        guard provider != destination,
              order.contains(provider),
              order.contains(destination)
        else { return }

        order.removeAll { $0 == provider }
        guard let destinationIndex = order.firstIndex(of: destination) else { return }
        order.insert(provider, at: destinationIndex)
        persistOrder()
    }

    /// Moves the dragged card into the destination's current grid slot. The
    /// destination card fills the source gap as soon as the pointer crosses it.
    func move(_ provider: ProviderQuota.Provider, to destination: ProviderQuota.Provider) {
        guard provider != destination,
              order.contains(provider),
              let destinationIndex = order.firstIndex(of: destination)
        else { return }

        order.removeAll { $0 == provider }
        order.insert(provider, at: min(destinationIndex, order.count))
        persistOrder()
    }

    /// Onboarding 的一次性确认:写入选择并标记完成。
    func completeOnboarding(enabled selection: Set<ProviderQuota.Provider>) {
        enabled = selection
        persistEnabled()
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Self.onboardingKey)
    }

    private func persistEnabled() {
        defaults.set(Self.allProviders.filter(enabled.contains).map(\.rawValue), forKey: Self.enabledKey)
    }

    private func persistOrder() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
    }

    private static func mergedOrder(_ rawOrder: [String]) -> [ProviderQuota.Provider] {
        var seen = Set<ProviderQuota.Provider>()
        let saved = rawOrder
            .compactMap(ProviderQuota.Provider.init(rawValue:))
            .filter { seen.insert($0).inserted }
        return saved + allProviders.filter { !seen.contains($0) }
    }

    // MARK: - 本机安装检测

    struct Detection: Identifiable {
        let provider: ProviderQuota.Provider
        let installed: Bool
        /// 已检测到时的来源说明 / 未检测到时的接入指引。
        let detail: String

        var id: ProviderQuota.Provider { provider }
    }

    /// 纯本地存在性检查(目录/文件/已配置的 Key),不发网络请求、
    /// 不读钥匙串凭证内容,毫秒级完成。
    nonisolated static func detections(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Detection] {
        let fileManager = FileManager.default
        func exists(_ path: String) -> Bool {
            fileManager.fileExists(atPath: home.appending(path: path).path)
        }

        var zaiStore = ZAIKeyStore()
        zaiStore.environment = environment
        zaiStore.homeDirectory = home
        var openRouterStore = OpenRouterKeyStore()
        openRouterStore.environment = environment
        openRouterStore.homeDirectory = home

        func detection(
            _ provider: ProviderQuota.Provider,
            installed: Bool,
            found: String,
            hint: String
        ) -> Detection {
            Detection(provider: provider, installed: installed, detail: installed ? found : hint)
        }

        let cursorInstalled = exists("Library/Application Support/Cursor")
            || fileManager.fileExists(atPath: "/Applications/Cursor.app")
        let copilotInstalled = exists(".config/github-copilot") || exists(".config/gh/hosts.yml")
        let devinInstalled = exists(".local/share/devin/credentials.toml")
            || exists("Library/Application Support/Devin")
        let antigravityInstalled = fileManager.fileExists(atPath: "/Applications/Antigravity.app")
            || exists("Library/Application Support/Antigravity")
        let opencodeInstalled = exists(".local/share/opencode")
            || environment["OPENCODE_DATA_DIR"]?.isEmpty == false

        return [
            detection(.claude, installed: exists(".claude"),
                      found: "检测到 ~/.claude(Claude Code 已安装)",
                      hint: "安装并登录 Claude Code 后自动接入"),
            detection(.codex, installed: exists(".codex"),
                      found: "检测到 ~/.codex(Codex CLI 已安装)",
                      hint: "安装并登录 Codex CLI 后自动接入"),
            detection(.cursor, installed: cursorInstalled,
                      found: "检测到 Cursor 应用数据",
                      hint: "安装并登录 Cursor 后自动接入"),
            detection(.copilot, installed: copilotInstalled,
                      found: "检测到 GitHub Copilot / gh CLI 配置",
                      hint: "在编辑器登录 Copilot 或运行 gh auth login 后自动接入"),
            detection(.devin, installed: devinInstalled,
                      found: "检测到 Devin 应用数据",
                      hint: "安装并登录 Devin 后自动接入"),
            detection(.grok, installed: exists(".grok/auth.json"),
                      found: "检测到 ~/.grok 登录凭证",
                      hint: "运行一次 grok 并登录后自动接入"),
            detection(.openrouter, installed: openRouterStore.load() != nil,
                      found: "检测到已配置的 OpenRouter API Key",
                      hint: "需要 API Key；开启后在「数据源」页粘贴一次即可"),
            detection(.antigravity, installed: antigravityInstalled,
                      found: "检测到 Antigravity 应用",
                      hint: "安装并登录 Antigravity 后自动接入"),
            detection(.opencode, installed: opencodeInstalled,
                      found: "检测到 OpenCode 本地数据",
                      hint: "安装并登录 OpenCode Go 后自动接入"),
            detection(.zai, installed: zaiStore.load() != nil,
                      found: "检测到已配置的 Z.ai API Key",
                      hint: "需要 API Key；开启后在「数据源」页粘贴一次即可")
        ]
    }
}
