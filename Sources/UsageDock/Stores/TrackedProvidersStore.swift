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
    static let connectedKey = "tokenRemain.connectedProviders.v1"

    /// UI 展示与遍历用的稳定顺序。
    static let allProviders = ProviderQuota.Provider.displayOrder

    @Published private(set) var enabled: Set<ProviderQuota.Provider>
    @Published private(set) var order: [ProviderQuota.Provider]
    @Published private(set) var hasCompletedOnboarding: Bool
    /// 至少成功读取过一次额度的 provider。与“正在追踪”分开持久化：
    /// 链路或凭据后来失效时，数据来源页仍应保留该应用并提示故障。
    @Published private(set) var connected: Set<ProviderQuota.Provider>

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
        let rawConnected = (defaults.array(forKey: Self.connectedKey) as? [String]) ?? []
        connected = Set(rawConnected.compactMap(ProviderQuota.Provider.init(rawValue:)))
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

    var connectedOrdered: [ProviderQuota.Provider] {
        Self.allProviders.filter(connected.contains)
    }

    func isEnabled(_ provider: ProviderQuota.Provider) -> Bool {
        enabled.contains(provider)
    }

    func hasConnected(_ provider: ProviderQuota.Provider) -> Bool {
        connected.contains(provider)
    }

    /// 只在一次真实读取成功后调用。连接历史不因后续失败、清除 Key 或
    /// 停止追踪而删除，确保失效的数据链仍然可见、可诊断。
    func markConnected(_ provider: ProviderQuota.Provider) {
        guard connected.insert(provider).inserted else { return }
        defaults.set(
            Self.allProviders.filter(connected.contains).map(\.rawValue),
            forKey: Self.connectedKey
        )
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

        let detections = [
            detection(.claude, installed: exists(".claude"),
                      found: L10n.text("provider.detect.claude.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Claude Code")),
            detection(.codex, installed: exists(".codex"),
                      found: L10n.text("provider.detect.codex.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Codex CLI")),
            detection(.cursor, installed: cursorInstalled,
                      found: L10n.text("provider.detect.cursor.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Cursor")),
            detection(.copilot, installed: copilotInstalled,
                      found: L10n.text("provider.detect.copilot.found"),
                      hint: L10n.text("provider.detect.copilot.hint")),
            detection(.devin, installed: devinInstalled,
                      found: L10n.text("provider.detect.devin.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Devin")),
            detection(.grok, installed: exists(".grok/auth.json"),
                      found: L10n.text("provider.detect.grok.found"),
                      hint: L10n.text("provider.detect.grok.hint")),
            detection(.openrouter, installed: openRouterStore.load() != nil,
                      found: L10n.format("provider.detect.found_api_key", "OpenRouter"),
                      hint: L10n.text("provider.detect.needs_api_key_hint")),
            detection(.antigravity, installed: antigravityInstalled,
                      found: L10n.text("provider.detect.antigravity.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Antigravity")),
            detection(.opencode, installed: opencodeInstalled,
                      found: L10n.text("provider.detect.opencode.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "OpenCode Go")),
            detection(.zai, installed: zaiStore.load() != nil,
                      found: L10n.format("provider.detect.found_api_key", "Z.ai"),
                      hint: L10n.text("provider.detect.needs_api_key_hint")),
            detection(.kiro, installed: KiroUsageService.cliPath() != nil,
                      found: L10n.text("provider.detect.kiro.found"),
                      hint: L10n.text("provider.detect.kiro.hint"))
        ] + Self.secretDetections(home: home, environment: environment)
        // 稳定排序:与 displayOrder 一致,onboarding 列表顺序不抖动。
        let order = ProviderQuota.Provider.displayOrder
        return detections.sorted {
            (order.firstIndex(of: $0.provider) ?? .max) < (order.firstIndex(of: $1.provider) ?? .max)
        }
    }

    /// token-monitor 兼容层的密钥/Cookie 型 provider:凭据在即视为已接入。
    private nonisolated static func secretDetections(
        home: URL,
        environment: [String: String]
    ) -> [Detection] {
        ProviderSecretStore.descriptors.map { descriptor in
            var store = ProviderSecretStore(provider: descriptor.provider)
            store.environment = environment
            let configured = store.load() != nil
            return Detection(
                provider: descriptor.provider,
                installed: configured,
                detail: configured
                    ? L10n.format("provider.detect.found_credentials", descriptor.provider.displayName)
                    : L10n.text(
                        descriptor.isCookie
                            ? "provider.detect.needs_cookie_hint"
                            : "provider.detect.needs_api_key_hint"
                    )
            )
        }
    }
}
