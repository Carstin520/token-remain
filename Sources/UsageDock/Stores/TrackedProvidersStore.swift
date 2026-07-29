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
    static let detectedInstallationsKey = "tokenRemain.detectedInstallations.v1"

    /// UI 展示与遍历用的稳定顺序。
    static let allProviders = ProviderQuota.Provider.displayOrder

    @Published private(set) var enabled: Set<ProviderQuota.Provider>
    @Published private(set) var order: [ProviderQuota.Provider]
    @Published private(set) var hasCompletedOnboarding: Bool
    /// 至少成功读取过一次额度的 provider。与“正在追踪”分开持久化：
    /// 链路或凭据后来失效时，数据来源页仍应保留该应用并提示故障。
    @Published private(set) var connected: Set<ProviderQuota.Provider>
    /// TokenRemain 运行期间新出现、且用户尚未追踪的本机应用。Dashboard
    /// 消费这条队列并逐个询问，扫描本身只做本地文件存在性检查。
    @Published private(set) var pendingDetectionSuggestions: [Detection] = []

    private let defaults: UserDefaults
    private var detectionTask: Task<Void, Never>?

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

    /// 「数据源」页既要保留曾成功连接过的来源用于故障诊断，也必须让当前
    /// 已追踪、但尚未首次连接的手动凭据型来源显示输入框。否则 Z.ai 这类
    /// provider 会陷入“没有 Key 无法连接、没有连接又看不到 Key 输入框”的
    /// 首次使用死循环。Claude/Codex 同理需要先显示显式 Keychain 授权入口。
    var dataSourceOrdered: [ProviderQuota.Provider] {
        Self.allProviders.filter { provider in
            connected.contains(provider)
                || (
                    enabled.contains(provider)
                        && (
                            Self.requiresManualCredential(provider)
                                || Self.supportsCredentialAuthorization(provider)
                        )
                )
        }
    }

    static func supportsCredentialAuthorization(_ provider: ProviderQuota.Provider) -> Bool {
        provider == .claude || provider == .codex
    }

    static func requiresManualCredential(_ provider: ProviderQuota.Provider) -> Bool {
        switch provider {
        case .zai, .openrouter:
            true
        default:
            ProviderSecretStore.descriptor(for: provider) != nil
        }
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
            pendingDetectionSuggestions.removeAll { $0.provider == provider }
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
        pendingDetectionSuggestions.removeAll()
        persistEnabled()
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Self.onboardingKey)
    }

    /// 每 10 秒做一次极轻量本机检查；应用重新变为前台时还会立即补扫。
    /// 首次启用该功能只建立基线，不把升级用户已经明确停用的应用重新弹出。
    func startDetectionMonitoring() {
        guard detectionTask == nil else { return }
        scanForNewInstallations()
        detectionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                self?.scanForNewInstallations()
            }
        }
    }

    func scanForNewInstallations() {
        applyAutomaticDetections(Self.automaticDetections())
    }

    /// 将纯检测结果转成一次性建议。当前检测集合会持久化，因此 TokenRemain
    /// 关闭期间安装的工具也能在下次启动时与上次基线比较出来。
    @discardableResult
    func applyAutomaticDetections(_ detections: [Detection]) -> [Detection] {
        let current = Set(detections.filter(\.installed).map(\.provider))
        guard defaults.object(forKey: Self.detectedInstallationsKey) != nil else {
            persistDetectedInstallations(current)
            return []
        }

        let previousRaw = defaults.array(forKey: Self.detectedInstallationsKey) as? [String] ?? []
        let previous = Set(previousRaw.compactMap(ProviderQuota.Provider.init(rawValue:)))
        persistDetectedInstallations(current)

        let queued = Set(pendingDetectionSuggestions.map(\.provider))
        let newlyDetected = current.subtracting(previous)
        let suggestions = detections.filter {
            $0.installed
                && newlyDetected.contains($0.provider)
                && !enabled.contains($0.provider)
                && !queued.contains($0.provider)
        }
        pendingDetectionSuggestions.append(contentsOf: suggestions)
        return suggestions
    }

    func acceptNextDetectionSuggestion() {
        guard let detection = pendingDetectionSuggestions.first else { return }
        setEnabled(detection.provider, true)
    }

    func dismissNextDetectionSuggestion() {
        guard !pendingDetectionSuggestions.isEmpty else { return }
        pendingDetectionSuggestions.removeFirst()
    }

    private func persistEnabled() {
        defaults.set(Self.allProviders.filter(enabled.contains).map(\.rawValue), forKey: Self.enabledKey)
    }

    private func persistOrder() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
    }

    private func persistDetectedInstallations(_ providers: Set<ProviderQuota.Provider>) {
        defaults.set(
            Self.allProviders.filter(providers.contains).map(\.rawValue),
            forKey: Self.detectedInstallationsKey
        )
    }

    private static func mergedOrder(_ rawOrder: [String]) -> [ProviderQuota.Provider] {
        var seen = Set<ProviderQuota.Provider>()
        let saved = rawOrder
            .compactMap(ProviderQuota.Provider.init(rawValue:))
            .filter { seen.insert($0).inserted }
        return saved + allProviders.filter { !seen.contains($0) }
    }

    // MARK: - 本机安装检测

    struct Detection: Identifiable, Equatable {
        let provider: ProviderQuota.Provider
        let installed: Bool
        /// 已检测到时的来源说明 / 未检测到时的接入指引。
        let detail: String

        var id: ProviderQuota.Provider { provider }
    }

    /// 纯本地存在性检查(目录/文件/已配置的 Key)，不发网络请求。
    /// 后台自动扫描传 `includeManualCredentials: false`，因此不会轮询钥匙串；
    /// onboarding 的完整扫描只会非交互读取 app 自己保存的凭据。
    nonisolated static func detections(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationDirectories: [URL]? = nil,
        includeManualCredentials: Bool = true
    ) -> [Detection] {
        let fileManager = FileManager.default
        let appDirectories = applicationDirectories ?? [
            home.appending(path: "Applications"),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]
        func exists(_ path: String) -> Bool {
            fileManager.fileExists(atPath: home.appending(path: path).path)
        }
        func appExists(_ names: String...) -> Bool {
            appDirectories.contains { directory in
                names.contains { name in
                    fileManager.fileExists(atPath: directory.appending(path: name).path)
                }
            }
        }
        func executableExists(_ name: String, homeCandidates: [String] = []) -> Bool {
            var candidates = homeCandidates.map { home.appending(path: $0).path }
            candidates.append(contentsOf: [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)"
            ])
            if let path = environment["PATH"] {
                candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/\(name)" })
            }
            return candidates.contains(where: fileManager.isExecutableFile(atPath:))
        }
        func directoryContains(_ path: String, prefix: String) -> Bool {
            let directory = home.appending(path: path)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return false }
            return entries.contains { $0.lastPathComponent.hasPrefix(prefix) }
        }

        func detection(
            _ provider: ProviderQuota.Provider,
            installed: Bool,
            found: String,
            hint: String
        ) -> Detection {
            Detection(provider: provider, installed: installed, detail: installed ? found : hint)
        }

        let cursorInstalled = exists("Library/Application Support/Cursor")
            || exists("Applications/Cursor.app")
            || fileManager.fileExists(atPath: "/Applications/Cursor.app")
        let copilotInstalled = exists(".config/github-copilot")
            || exists(".config/gh/hosts.yml")
            || directoryContains(".vscode/extensions", prefix: "github.copilot")
            || directoryContains(".cursor/extensions", prefix: "github.copilot")
        let devinInstalled = exists(".local/share/devin/credentials.toml")
            || exists("Library/Application Support/Devin")
            || exists("Applications/Devin.app")
            || fileManager.fileExists(atPath: "/Applications/Devin.app")
        let windsurfInstalled = exists("Library/Application Support/Windsurf")
            || appExists("Windsurf.app")
            || environment["WINDSURF_API_KEY"]?.isEmpty == false
        let antigravityInstalled = fileManager.fileExists(atPath: "/Applications/Antigravity.app")
            || exists("Applications/Antigravity.app")
            || exists("Library/Application Support/Antigravity")
        let opencodeInstalled = exists(".local/share/opencode")
            || environment["OPENCODE_DATA_DIR"]?.isEmpty == false
            || executableExists(
                "opencode",
                homeCandidates: [".local/bin/opencode", ".opencode/bin/opencode"]
            )
        let claudeInstalled = exists(".claude")
            || appExists("Claude.app")
            || executableExists(
                "claude",
                homeCandidates: [".local/bin/claude", ".npm-global/bin/claude"]
            )
        let codexInstalled = exists(".codex")
            || appExists("ChatGPT.app", "Codex.app")
            || executableExists(
                "codex",
                homeCandidates: [".local/bin/codex", ".npm-global/bin/codex"]
            )
        let grokInstalled = exists(".grok/auth.json")
            || executableExists("grok", homeCandidates: [".local/bin/grok"])
        let kiroInstalled = KiroUsageService.cliPath(home: home, environment: environment) != nil
            || exists("Applications/Kiro.app")
            || fileManager.fileExists(atPath: "/Applications/Kiro.app")

        var detections = [
            detection(.claude, installed: claudeInstalled,
                      found: L10n.text("provider.detect.claude.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Claude Desktop / Claude Code")),
            detection(.codex, installed: codexInstalled,
                      found: L10n.text("provider.detect.codex.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "ChatGPT / Codex")),
            detection(.cursor, installed: cursorInstalled,
                      found: L10n.text("provider.detect.cursor.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Cursor")),
            detection(.copilot, installed: copilotInstalled,
                      found: L10n.text("provider.detect.copilot.found"),
                      hint: L10n.text("provider.detect.copilot.hint")),
            detection(.devin, installed: devinInstalled,
                      found: L10n.text("provider.detect.devin.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Devin")),
            detection(.windsurf, installed: windsurfInstalled,
                      found: L10n.text("provider.detect.windsurf.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Windsurf")),
            detection(.grok, installed: grokInstalled,
                      found: L10n.text("provider.detect.grok.found"),
                      hint: L10n.text("provider.detect.grok.hint")),
            detection(.antigravity, installed: antigravityInstalled,
                      found: L10n.text("provider.detect.antigravity.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "Antigravity")),
            detection(.opencode, installed: opencodeInstalled,
                      found: L10n.text("provider.detect.opencode.found"),
                      hint: L10n.format("provider.detect.install_login_hint", "OpenCode Go")),
            detection(.kiro, installed: kiroInstalled,
                      found: L10n.text("provider.detect.kiro.found"),
                      hint: L10n.text("provider.detect.kiro.hint"))
        ]
        if includeManualCredentials {
            var zaiStore = ZAIKeyStore()
            zaiStore.environment = environment
            zaiStore.homeDirectory = home
            var openRouterStore = OpenRouterKeyStore()
            openRouterStore.environment = environment
            openRouterStore.homeDirectory = home
            detections += [
                detection(.openrouter, installed: openRouterStore.load() != nil,
                          found: L10n.format("provider.detect.found_api_key", "OpenRouter"),
                          hint: L10n.text("provider.detect.needs_api_key_hint")),
                detection(.zai, installed: zaiStore.load() != nil,
                          found: L10n.format("provider.detect.found_api_key", "Z.ai"),
                          hint: L10n.text("provider.detect.needs_api_key_hint"))
            ]
            detections += Self.secretDetections(home: home, environment: environment)
        }
        // 稳定排序:与 displayOrder 一致,onboarding 列表顺序不抖动。
        let order = ProviderQuota.Provider.displayOrder
        return detections.sorted {
            (order.firstIndex(of: $0.provider) ?? .max) < (order.firstIndex(of: $1.provider) ?? .max)
        }
    }

    nonisolated static func automaticDetections(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Detection] {
        detections(home: home, environment: environment, includeManualCredentials: false)
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

    deinit {
        detectionTask?.cancel()
    }
}
