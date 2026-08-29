import Combine
import Foundation
import OSLog
import TokenRemainSyncKit

@MainActor
final class UsageStore: ObservableObject {
    enum LocalUsageStatus: Equatable {
        /// No bundled-helper result has completed in this process yet.
        case loading
        /// Today's report contains at least one real agent row.
        case available
        /// The helper completed successfully, but today has no local events.
        case empty
        /// The bundled helper could not be executed or its output was invalid.
        case failed(String)
    }

    nonisolated static func localUsageStatus(for daily: DailyUsage) -> LocalUsageStatus {
        daily.agents.isEmpty ? .empty : .available
    }

    struct LogoQuotaSelection: Equatable {
        let provider: ProviderQuota.Provider
        let remainingPercent: Double
        let windowMinutes: Int
    }

    /// 各 provider 当前展示快照的合并视图。逐 provider 的具名访问器保留在下方,
    /// 视图无需感知本机与 Direct Sync 快照的分层。
    @Published private(set) var quotas: [ProviderQuota.Provider: ProviderQuota] = [:]
    /// Device-local readings remain separate from direct-sync readings so a
    /// Windows snapshot is never cached or echoed back as if this Mac produced it.
    private var localQuotas: [ProviderQuota.Provider: ProviderQuota] = [:]
    private var directSyncSnapshots: [UUID: MobileUsageSnapshot] = [:]

    var claude: ProviderQuota? { quotas[.claude] }
    var codex: ProviderQuota? { quotas[.codex] }
    var cursor: ProviderQuota? { quotas[.cursor] }
    var grok: ProviderQuota? { quotas[.grok] }
    var zai: ProviderQuota? { quotas[.zai] }
    var copilot: ProviderQuota? { quotas[.copilot] }
    var devin: ProviderQuota? { quotas[.devin] }
    var windsurf: ProviderQuota? { quotas[.windsurf] }
    var openrouter: ProviderQuota? { quotas[.openrouter] }
    var antigravity: ProviderQuota? { quotas[.antigravity] }
    var opencode: ProviderQuota? { quotas[.opencode] }
    /// 直查 provider 卡片内的状态说明(登录过期、接口错误等)。
    /// 刻意不进全局错误条:"未接入某工具"是卡片语境的信息,
    /// 不该像故障一样反复告警。
    @Published private(set) var providerNotices: [ProviderQuota.Provider: String] = [:]
    /// Additive multi-account state. The provider-keyed `localQuotas` remains
    /// the system-account compatibility projection for persistence/sync/history.
    @Published private(set) var providerAccountProfiles: [ProviderAccountProfile] = []
    @Published private(set) var providerAccountStates: [ProviderAccountID: ProviderAccountState] = [:]
    @Published private(set) var providerAccountSelections: [ProviderQuota.Provider: ProviderAccountSelection] = [:]
    @Published private(set) var addingProviderAccounts: Set<ProviderQuota.Provider> = []
    @Published private(set) var accountManagementNotices: [ProviderQuota.Provider: String] = [:]

    var isAddingClaudeAccount: Bool { addingProviderAccounts.contains(.claude) }
    var accountManagementNotice: String? { accountManagementNotices[.claude] }

    func isAddingProviderAccount(_ provider: ProviderQuota.Provider) -> Bool {
        addingProviderAccounts.contains(provider)
    }

    func accountManagementNotice(for provider: ProviderQuota.Provider) -> String? {
        accountManagementNotices[provider]
    }

    func clearAccountManagementNotice(for provider: ProviderQuota.Provider) {
        accountManagementNotices[provider] = nil
    }
    @Published private(set) var daily: DailyUsage?
    @Published private(set) var history: DailyUsageHistory?
    @Published private(set) var quotaUsageHistory: QuotaUsageHistory = .empty
    /// Official public service status for providers that publish a dedicated
    /// coding-product component (currently Claude Code and Codex).
    @Published private(set) var serviceStatuses: [ProviderQuota.Provider: ProviderServiceStatus] = [:]
    @Published private(set) var localUsageStatus: LocalUsageStatus = .loading
    @Published private(set) var discoveredLocalUsageSourceIDs: Set<String> = []
    @Published private(set) var disabledLocalUsageSourceIDs: Set<String> = []
    @Published private(set) var traeAgentDirectories: [URL] = []

    var configuredTraeAgentDirectories: [URL] {
        traeAgentTrajectoryStore.configuredDirectories
    }
    @Published private(set) var isCCUsageRefreshing = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let tracked: TrackedProvidersStore
    private let defaults: UserDefaults
    private let providerAccountsStore: ProviderAccountsStore
    private let traeAgentTrajectoryStore: TraeAgentTrajectoryStore
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var lastCCUsageRefresh: Date?
    private var lastClaudeAttempt: Date?
    private var lastCodexAPIAttempt: Date?
    private var lastCodexLocalAttempt: Date?
    private var lastServiceStatusAttempt: Date?
    private var lastAuxProviderAttempts: [ProviderQuota.Provider: Date] = [:]
    private var auxProviderFailureCounts: [ProviderQuota.Provider: Int] = [:]
    private var auxProviderRetryAfter: [ProviderQuota.Provider: Date] = [:]
    private var claudeRetryAfter: Date?
    private var claudeConsecutiveFailures = 0
    private var lowLatencySyncEnabled = false
    /// 由状态栏控制器注入:本地用量正出现在任一可见界面(弹窗/仪表板/
    /// 浮窗)时返回 true。后台 ccusage 扫描据此决定是否维持分钟级节奏。
    var localUsageUIVisibilityProvider: (() -> Bool)?
    private let quotaCache = QuotaCache()
    private let sessionAlerts = ProviderSessionAlertCenter.shared
    private let providerAccountQuotaCache = ProviderAccountQuotaCache()
    private let historyCache = DailyHistoryCache()
    private let quotaUsageHistoryCache = QuotaUsageHistoryCache()
    private let logger = Logger(subsystem: "com.jamesli.usagedock", category: "UsageRefresh")
    private let claudeRetryAfterKey = "claudeRetryAfter"
    private let serviceStatusRefreshInterval: TimeInterval = 300
    private var quotaErrorMessage: String?
    private var historyErrorMessage: String?
    private var latestLocalUsageSnapshot: LocalUsageSnapshot?
    private let disabledLocalUsageSourcesKey = "tokenRemain.disabledLocalUsageSources.v1"
    private let sessionActivityMonitor: LocalAISessionActivityMonitor
    private let hostQuotaRouter: HostAppQuotaRoutingService

    private enum QuotaRefreshOutput {
        case claude(Result<ProviderQuota, Error>)
        case providerAccount(ProviderAccountProfile, Result<ProviderQuota, Error>)
        case codex(Result<ProviderQuota, Error>)
        case auxiliary(ProviderQuota.Provider, Result<ProviderQuota, Error>)
        case serviceStatuses([ProviderQuota.Provider: ProviderServiceStatus])
    }

    var claudeRemainingText: String {
        remainingText(for: claude)
    }

    var codexRemainingText: String {
        remainingText(for: codex)
    }

    var cursorRemainingText: String {
        remainingText(for: cursor)
    }

    /// The logo follows the most constrained available provider so the visual
    /// warning is never more optimistic than the quota cards below it.
    /// Claude / Codex 之外、只有 API(或本地扫描)一条直查路径的 provider,
    /// 统一走 5 分钟节奏的批量抓取。
    nonisolated static let auxProviders: [ProviderQuota.Provider] = [
        .cursor, .grok, .zai, .zaiTeam, .copilot, .devin, .windsurf,
        .openrouter, .antigravity, .opencode,
        .deepseek, .kimi, .minimax, .mimo, .qoder, .kiro, .volcengine, .ollama,
        .thirdParty
    ]

    /// 当前全部 provider 快照(含未追踪的 nil),固定顺序。
    private var allQuotas: [ProviderQuota?] {
        TrackedProvidersStore.allProviders.map(quotaValue(for:))
    }

    var aggregateRemainingPercent: Double? {
        Self.logoQuotaSelection(
            from: allQuotas,
            strategy: PreferencesStore.shared.quotaSummaryStrategy
        )?.remainingPercent
    }

    var logoQuotaSelection: LogoQuotaSelection? {
        Self.logoQuotaSelection(
            from: allQuotas,
            strategy: PreferencesStore.shared.quotaSummaryStrategy
        )
    }

    func quotaValue(for provider: ProviderQuota.Provider) -> ProviderQuota? {
        quotas[provider]
    }

    var connectedProviders: [ProviderQuota.Provider] {
        tracked.connectedOrdered
    }

    var dataSourceProviders: [ProviderQuota.Provider] {
        tracked.dataSourceOrdered
    }

    func accountSnapshots(for provider: ProviderQuota.Provider) -> [ProviderAccountSnapshot] {
        let providerProfiles = providerAccountProfiles.filter { $0.provider == provider }
        let hasManagedProfile = providerProfiles.contains { !$0.isSystem }
        return providerProfiles.compactMap { profile in
            let state = providerAccountStates[profile.id] ?? ProviderAccountState()
            // A key/cookie provider has no meaningful "current account" until
            // its ordinary global credential resolves. Once a managed profile
            // exists, hide that empty placeholder so the first real account is
            // not presented as "1 of 2 available". CLI-backed system accounts
            // remain visible because their local login is independently useful.
            if profile.isSystem,
               hasManagedProfile,
               profile.provider.multiAccountCapability?.credentialKind == .keychainSecret,
               state.quota == nil {
                return nil
            }
            return ProviderAccountSnapshot(
                profile: profile,
                state: state
            )
        }
    }

    func accountSummary(for provider: ProviderQuota.Provider) -> ProviderAccountSummary {
        ProviderAccountSummary(snapshots: accountSnapshots(for: provider))
    }

    func accountSelection(for provider: ProviderQuota.Provider) -> ProviderAccountSelection {
        providerAccountSelections[provider] ?? .all
    }

    func setAccountSelection(
        _ selection: ProviderAccountSelection,
        for provider: ProviderQuota.Provider
    ) {
        providerAccountsStore.setSelection(selection, for: provider)
        providerAccountSelections = providerAccountsStore.selections
    }

    func displayedQuota(for provider: ProviderQuota.Provider) -> ProviderQuota? {
        guard case .account(let id) = accountSelection(for: provider) else {
            return quotaValue(for: provider)
        }
        // Never substitute another account's reading. A managed account that
        // has not answered yet must render unavailable, not the system quota.
        return providerAccountStates[id]?.quota
    }

    func displayedNotice(for provider: ProviderQuota.Provider) -> String? {
        guard case .account(let id) = accountSelection(for: provider) else {
            return providerNotices[provider]
        }
        return providerAccountStates[id]?.notice
    }

    var localUsageSourceIDs: [String] {
        discoveredLocalUsageSourceIDs.sorted {
            LocalUsageSourceCatalog.sortKey($0) < LocalUsageSourceCatalog.sortKey($1)
        }
    }

    func isLocalUsageSourceEnabled(_ id: String) -> Bool {
        !disabledLocalUsageSourceIDs.contains(LocalUsageSourceCatalog.canonicalID(id))
    }

    func setLocalUsageSourceEnabled(_ enabled: Bool, id: String) {
        let canonical = LocalUsageSourceCatalog.canonicalID(id)
        guard LocalUsageSourceCatalog.isWellFormed(canonical) else { return }
        if enabled {
            disabledLocalUsageSourceIDs.remove(canonical)
        } else {
            disabledLocalUsageSourceIDs.insert(canonical)
        }
        defaults.set(Array(disabledLocalUsageSourceIDs).sorted(), forKey: disabledLocalUsageSourcesKey)
        if let latestLocalUsageSnapshot {
            applyLocalUsageSnapshot(latestLocalUsageSnapshot)
        } else {
            refreshLocalUsage()
        }
    }

    func addTraeAgentDirectory(_ url: URL) {
        traeAgentTrajectoryStore.add(url)
        reloadTraeAgentDirectories()
        refreshLocalUsage()
    }

    func removeTraeAgentDirectory(_ url: URL) {
        traeAgentTrajectoryStore.remove(url)
        reloadTraeAgentDirectories()
        refreshLocalUsage()
    }

    private func assign(_ value: ProviderQuota?, to provider: ProviderQuota.Provider) {
        let resolvedValue: ProviderQuota?
        if let value, let previous = localQuotas[provider],
           Self.quotaRoutesMatch(value, previous) {
            resolvedValue = value.retainingActiveScopedWindows(
                from: previous,
                now: value.capturedAt
            )
        } else {
            resolvedValue = value
        }

        if resolvedValue != nil {
            tracked.markConnected(provider)
        }
        localQuotas[provider] = resolvedValue
        recomputeEffectiveQuotas()
        let systemID = ProviderAccountID.system(provider)
        if providerAccountProfiles.contains(where: { $0.id == systemID }) {
            var state = providerAccountStates[systemID] ?? ProviderAccountState()
            state.quota = resolvedValue
            state.isRefreshing = false
            providerAccountStates[systemID] = state
        }
        if let resolvedValue {
            let updated = quotaUsageHistory.recording(resolvedValue)
            if updated != quotaUsageHistory {
                quotaUsageHistory = updated
                quotaUsageHistoryCache.save(updated)
            }
        }
    }

    nonisolated static func quotaRoutesMatch(
        _ lhs: ProviderQuota,
        _ rhs: ProviderQuota
    ) -> Bool {
        lhs.attribution?.routeIdentifier == rhs.attribution?.routeIdentifier
    }

    private static func auxFetcher(
        for provider: ProviderQuota.Provider
    ) -> (@Sendable () async throws -> ProviderQuota)? {
        switch provider {
        case .cursor: return { try await CursorUsageService().fetch() }
        case .grok: return { try await GrokUsageService().fetch() }
        case .zai: return { try await ZAIUsageService().fetch() }
        case .zaiTeam: return { try await ZAITeamUsageService().fetch() }
        case .copilot: return { try await CopilotUsageService().fetch() }
        case .devin: return { try await DevinUsageService().fetch() }
        case .windsurf: return { try await WindsurfUsageService().fetch() }
        case .openrouter: return { try await OpenRouterUsageService().fetch() }
        case .antigravity: return { try await AntigravityUsageService().fetch() }
        case .opencode: return { try await OpenCodeUsageService().fetch() }
        case .deepseek: return { try await DeepSeekUsageService().fetch() }
        case .kimi: return { try await KimiUsageService().fetch() }
        case .minimax: return { try await MiniMaxUsageService().fetch() }
        case .mimo: return { try await MiMoUsageService().fetch() }
        case .qoder: return { try await QoderUsageService().fetch() }
        case .kiro: return { try await KiroUsageService().fetch() }
        case .volcengine: return { try await VolcengineUsageService().fetch() }
        case .ollama: return { try await OllamaUsageService().fetch() }
        case .thirdParty: return { try await ThirdPartyUsageService().fetch() }
        case .claude, .codex: return nil
        }
    }

    private static func fetchAux(
        providers: [ProviderQuota.Provider]
    ) async -> [ProviderQuota.Provider: Result<ProviderQuota, Error>] {
        await withTaskGroup(
            of: (ProviderQuota.Provider, Result<ProviderQuota, Error>).self
        ) { group in
            for provider in providers {
                guard let fetcher = auxFetcher(for: provider) else { continue }
                group.addTask {
                    do { return (provider, .success(try await fetcher())) }
                    catch { return (provider, .failure(error)) }
                }
            }
            var results: [ProviderQuota.Provider: Result<ProviderQuota, Error>] = [:]
            for await (provider, result) in group {
                results[provider] = result
            }
            return results
        }
    }

    static func aggregateRemainingPercent(
        from quotas: [ProviderQuota?],
        strategy: QuotaSummaryStrategy = .shortestWindow
    ) -> Double? {
        logoQuotaSelection(from: quotas, strategy: strategy)?.remainingPercent
    }

    /// Each provider contributes the account-wide window selected by the user.
    /// Model-scoped limits remain explicit detail rows and cannot silently
    /// repaint the provider-level meter.
    static func logoQuotaSelection(
        from quotas: [ProviderQuota?],
        strategy: QuotaSummaryStrategy = .shortestWindow
    ) -> LogoQuotaSelection? {
        quotas.compactMap { quota -> LogoQuotaSelection? in
            guard let quota else { return nil }
            let summary = quota.generalQuotaSummary(strategy: strategy)

            return LogoQuotaSelection(
                provider: quota.provider,
                remainingPercent: summary.remainingPercent,
                windowMinutes: summary.window.windowMinutes
            )
        }
        .min(by: { $0.remainingPercent < $1.remainingPercent })
    }

    convenience init() {
        self.init(tracked: TrackedProvidersStore.shared)
    }

    init(
        tracked: TrackedProvidersStore,
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sessionActivityMonitor: LocalAISessionActivityMonitor = .shared,
        providerAccountsStore: ProviderAccountsStore? = nil
    ) {
        self.tracked = tracked
        self.defaults = defaults
        self.providerAccountsStore = providerAccountsStore ?? ProviderAccountsStore(defaults: defaults)
        self.sessionActivityMonitor = sessionActivityMonitor
        hostQuotaRouter = HostAppQuotaRoutingService(
            detector: HostAppQuotaRouteDetector(homeDirectory: home)
        )
        traeAgentTrajectoryStore = TraeAgentTrajectoryStore(defaults: defaults, home: home)
        disabledLocalUsageSourceIDs = Set(
            (defaults.stringArray(forKey: disabledLocalUsageSourcesKey) ?? [])
                .map(LocalUsageSourceCatalog.canonicalID)
                .filter(LocalUsageSourceCatalog.isWellFormed)
        )
        traeAgentDirectories = traeAgentTrajectoryStore.availableDirectories
        if let cached = quotaCache.load() {
            localQuotas = cached.byProvider
            for hostProvider in [ProviderQuota.Provider.claude, .codex] {
                let currentRoute = hostQuotaRouter.route(for: hostProvider)
                let cachedRouteID = localQuotas[hostProvider]?.attribution?.routeIdentifier
                let currentRouteID = currentRoute.source?.routeIdentifier
                if cachedRouteID != currentRouteID {
                    localQuotas[hostProvider] = nil
                }
            }
            // OpenCode's active provider is resolved asynchronously from its
            // message database. Do not flash any cached route at launch; the
            // initial auxiliary refresh immediately repopulates the right one.
            localQuotas[.opencode] = nil
            recomputeEffectiveQuotas()
            // 升级兼容：旧版没有独立连接历史，已有成功快照就是最可靠的
            // “曾连接”证据。
            for provider in localQuotas.keys {
                tracked.markConnected(provider)
            }
            lastClaudeAttempt = localQuotas[.claude]?.capturedAt
        }
        providerAccountProfiles = self.providerAccountsStore.allProfiles
        providerAccountSelections = self.providerAccountsStore.selections
        let cachedAccountQuotas = providerAccountQuotaCache.load()
        providerAccountStates = Dictionary(uniqueKeysWithValues: providerAccountProfiles.compactMap { profile in
            let cached = profile.isSystem ? localQuotas[profile.provider] : cachedAccountQuotas[profile.id]
            guard let cached else { return nil }
            return (profile.id, ProviderAccountState(quota: cached))
        })
        history = historyCache.load()
        discoveredLocalUsageSourceIDs.formUnion(
            history?.days.flatMap(\.agents).map { LocalUsageSourceCatalog.canonicalID($0.id) } ?? []
        )
        if !traeAgentDirectories.isEmpty {
            discoveredLocalUsageSourceIDs.insert(TraeAgentUsageService.agentID)
        }
        quotaUsageHistory = quotaUsageHistoryCache.load() ?? .empty
        claudeRetryAfter = UserDefaults.standard.object(forKey: claudeRetryAfterKey) as? Date
        pruneDisabledProviders()

        // 额度页/onboarding 增删追踪应用后:被移除的立即消失,
        // 新加入的立即拉取一次。
        tracked.$enabled
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.pruneDisabledProviders()
                Task { await self.refresh(forceCCUsage: false, forceClaude: true) }
            }
            .store(in: &cancellables)

        Task { @MainActor [weak self] in
            self?.start()
        }
    }

    /// 清掉未追踪 provider 的数据与提示,使菜单栏聚合、tooltip 与缓存
    /// 都立即反映用户的选择。
    private func pruneDisabledProviders() {
        for provider in TrackedProvidersStore.allProviders where !tracked.isEnabled(provider) {
            assign(nil, to: provider)
        }
        providerNotices = providerNotices.filter { tracked.isEnabled($0.key) }
        serviceStatuses = serviceStatuses.filter { tracked.isEnabled($0.key) }
        quotaCache.save(currentSnapshot())
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let clock = ContinuousClock()
            var nextProbe = clock.now
            var isInitialRefresh = true
            var lastScheduledRefresh: Date?
            // A cached request timestamp must not make a freshly launched menu-bar app
            // display a completed countdown for another five minutes. The refresh method
            // still honors an active server-rate-limit backoff.
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                let localSessionActive = sessionActivityMonitor.hasRecentSessionActivity(at: now)
                let primarySurfaceVisible = localUsageUIVisibilityProvider?() ?? false
                let auxiliaryInterval = Self.auxProviders.contains(where: tracked.isEnabled)
                    ? AdaptiveRefreshPolicy.auxiliaryQuotaInterval(
                        preferred: PreferencesStore.shared.refreshInterval,
                        lowLatencySyncEnabled: lowLatencySyncEnabled
                    )
                    : nil
                let scheduledInterval = AdaptiveRefreshPolicy.schedulerInterval(
                    localSessionActive: localSessionActive,
                    primarySurfaceVisible: primarySurfaceVisible,
                    auxiliaryQuotaInterval: auxiliaryInterval
                )
                let scheduledRefreshIsDue = lastScheduledRefresh.map {
                    now.timeIntervalSince($0) >= scheduledInterval
                } ?? true
                if isInitialRefresh || scheduledRefreshIsDue {
                    await refresh(
                        forceCCUsage: isInitialRefresh,
                        forceClaude: isInitialRefresh
                    )
                    lastScheduledRefresh = now
                    isInitialRefresh = false
                }
                // The session-activity timestamp read is deliberately cheap and
                // remains minute-level so a new Codex/Claude turn returns the app
                // to live cadence within one probe. Expensive refresh work above
                // falls to five minutes while idle.
                nextProbe += .seconds(AdaptiveRefreshPolicy.activeInterval)
                if nextProbe < clock.now {
                    nextProbe = clock.now
                }
                try? await Task.sleep(until: nextProbe, clock: clock)
            }
        }
    }

    /// Cross-device sync owns this override. It never changes the user's saved
    /// menu-bar preference; disabling sync immediately returns to that choice.
    func setLowLatencySyncEnabled(_ enabled: Bool) {
        guard enabled != lowLatencySyncEnabled else { return }
        lowLatencySyncEnabled = enabled
        guard enabled else { return }
        Task { await refresh(forceCCUsage: false, forceClaude: true) }
    }

    func refresh(forceCCUsage: Bool = true, forceClaude: Bool = false) async {
        // Local usage has its own task and must be scheduled before the quota
        // refresh lock. Otherwise opening the UI while a provider request is
        // running silently drops the user's forced ccusage refresh.
        refreshLocalUsage(force: forceCCUsage)
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        let localSessionActive = sessionActivityMonitor.hasRecentSessionActivity(at: now)
        let primarySurfaceVisible = localUsageUIVisibilityProvider?() ?? false
        // Codex/Claude 在本地 session 或界面活跃时保持分钟级；两者都空闲
        // 时至少退到 5 分钟。Apple 设备仍能收到 Mac 的周期快照，但不再
        // 让静止的 Mac 永久承担一分钟一次的账户请求和会话目录扫描。
        let localAIInterval = AdaptiveRefreshPolicy.localAIQuotaInterval(
            preferred: PreferencesStore.shared.refreshInterval,
            lowLatencySyncEnabled: lowLatencySyncEnabled,
            localSessionActive: localSessionActive,
            primarySurfaceVisible: primarySurfaceVisible
        )
        let auxiliaryInterval = AdaptiveRefreshPolicy.auxiliaryQuotaInterval(
            preferred: PreferencesStore.shared.refreshInterval,
            lowLatencySyncEnabled: lowLatencySyncEnabled
        )
        func autoDue(since date: Date?, interval: TimeInterval?) -> Bool {
            guard let interval else { return false }
            return date.map { now.timeIntervalSince($0) >= interval } ?? true
        }
        // 失败后写入的退避窗口是硬性拦截,不只是补触发条件:活跃会话的
        // 60 秒节奏不能在退避期内每分钟重新发起一次最长 30 秒的 PTY 探针。
        // 用户的手动刷新(forceClaude)仍可穿透。
        let claudeBackoffActive = claudeRetryAfter.map { now < $0 } ?? false
        let shouldRefreshClaude = tracked.isEnabled(.claude)
            && (
                forceClaude
                    || (!claudeBackoffActive
                        && autoDue(since: lastClaudeAttempt, interval: localAIInterval))
            )

        let codexAPIDue = forceClaude
            || autoDue(since: lastCodexAPIAttempt, interval: localAIInterval)
        let codexLocalDue = forceClaude || autoDue(
            since: lastCodexLocalAttempt,
            interval: AdaptiveRefreshPolicy.codexLocalSnapshotInterval(
                localSessionActive: localSessionActive,
                primarySurfaceVisible: primarySurfaceVisible
            )
        )

        // Status pages are independent of account refresh preferences. Poll at
        // a restrained five-minute cadence and allow the user's refresh action
        // to check immediately.
        let statusProviders: [ProviderQuota.Provider] = [.claude, .codex].filter(tracked.isEnabled)
        let serviceStatusDue = !statusProviders.isEmpty && (
            forceClaude
                || lastServiceStatusAttempt.map {
                    now.timeIntervalSince($0) >= serviceStatusRefreshInterval
                } ?? true
        )

        // async-let 的子任务不在主 actor 上,启用判断先在这里(主 actor)取好。
        let codexEnabled = tracked.isEnabled(.codex)
        let hostQuotaRouter = self.hostQuotaRouter
        let codexRouteIsExternal = hostQuotaRouter.route(for: .codex).isExternal
        let dueAuxProviders = Self.auxProviders.filter { provider in
            guard tracked.isEnabled(provider) else { return false }
            if forceClaude { return true }
            if let retryAfter = auxProviderRetryAfter[provider], now < retryAfter {
                return false
            }
            return autoDue(
                since: lastAuxProviderAttempts[provider],
                interval: auxiliaryInterval
            )
        }
        let managedDueProviders = Set(dueAuxProviders)
            .union(shouldRefreshClaude ? [.claude] : [])
            .union(codexAPIDue ? [.codex] : [])
        let dueManagedProfiles = providerAccountProfiles.filter {
            $0.kind == .managed && $0.isEnabled && managedDueProviders.contains($0.provider)
        }

        if shouldRefreshClaude {
            for id in [ProviderAccountID.system(.claude)] {
                var state = providerAccountStates[id] ?? ProviderAccountState()
                state.isRefreshing = true
                providerAccountStates[id] = state
            }
        }
        for provider in dueAuxProviders {
            let id = ProviderAccountID.system(provider)
            guard providerAccountProfiles.contains(where: { $0.id == id }) else { continue }
            var state = providerAccountStates[id] ?? ProviderAccountState()
            state.isRefreshing = true
            providerAccountStates[id] = state
        }
        if Self.shouldRefreshCodex(
            enabled: codexEnabled,
            routeIsExternal: codexRouteIsExternal,
            apiDue: codexAPIDue,
            localSnapshotDue: codexLocalDue
        ) {
            let id = ProviderAccountID.system(.codex)
            var state = providerAccountStates[id] ?? ProviderAccountState()
            state.isRefreshing = true
            providerAccountStates[id] = state
        }
        for profile in dueManagedProfiles {
            var state = providerAccountStates[profile.id] ?? ProviderAccountState()
            state.isRefreshing = true
            providerAccountStates[profile.id] = state
        }

        var errors: [String] = []
        await withTaskGroup(of: QuotaRefreshOutput.self) { group in
            if shouldRefreshClaude {
                group.addTask {
                    .claude(
                        await result {
                            try await hostQuotaRouter.fetchClaude()
                        }
                    )
                }
            }
            if Self.shouldRefreshCodex(
                enabled: codexEnabled,
                routeIsExternal: codexRouteIsExternal,
                apiDue: codexAPIDue,
                localSnapshotDue: codexLocalDue
            ) {
                group.addTask {
                    .codex(
                        await result {
                            try await hostQuotaRouter.fetchCodex(preferAPI: codexAPIDue)
                        }
                    )
                }
            }
            for provider in dueAuxProviders {
                guard let fetcher = Self.auxFetcher(for: provider) else { continue }
                group.addTask {
                    .auxiliary(provider, await result { try await fetcher() })
                }
            }
            for profile in dueManagedProfiles {
                group.addTask {
                    .providerAccount(
                        profile,
                        await result { try await ProviderAccountFetchService().fetch(profile) }
                    )
                }
            }
            if serviceStatusDue {
                group.addTask {
                    .serviceStatuses(
                        await ProviderStatusService().fetch(
                            providers: statusProviders,
                            checkedAt: now
                        )
                    )
                }
            }

            // Consume each provider as soon as it finishes. A slow local probe
            // must not withhold fresh Claude/Codex data from the UI or CloudKit.
            for await output in group {
                applyQuotaRefreshOutput(
                    output,
                    attemptedAt: now,
                    codexAPIDue: codexAPIDue,
                    errors: &errors
                )
                quotaCache.save(currentSnapshot())
                providerAccountQuotaCache.save(currentProviderAccountQuotas())
            }
        }

        quotaErrorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        publishErrors()
    }

    /// A surface presentation should immediately catch up data that became due
    /// during the idle cadence without turning every open/uncover event into a
    /// forced network request. Local usage follows the same due check; explicit
    /// surface opens can still force its pre-existing presentation refresh.
    func refreshForVisibleSurface() async {
        await refresh(forceCCUsage: false, forceClaude: false)
    }

    private func applyQuotaRefreshOutput(
        _ output: QuotaRefreshOutput,
        attemptedAt now: Date,
        codexAPIDue: Bool,
        errors: inout [String]
    ) {
        switch output {
        case .claude(let claudeResult):
            lastClaudeAttempt = now
            switch claudeResult {
            case .success(let value):
                assign(value, to: .claude)
                providerNotices[.claude] = nil
                claudeRetryAfter = nil
                claudeConsecutiveFailures = 0
                sessionAlerts.reportHealthy(.claude)
                UserDefaults.standard.removeObject(forKey: claudeRetryAfterKey)
                logger.info("Claude quota refreshed; primary usage: \(value.primary.usedPercent, privacy: .public)%, reset time available: \(value.primary.resetsAt != nil, privacy: .public)")
            case .failure(let error):
                if Self.invalidatesCachedQuota(error) {
                    assign(nil, to: .claude)
                }
                providerNotices[.claude] = error.localizedDescription
                // 卡片会继续渲染上一份成功的快照,看起来一切正常,所以登出这类
                // 只有用户能修的失败必须主动出声,不能只写在弹窗里等人来看。
                sessionAlerts.report(error: error, for: .claude, now: now)
                if let serviceError = error as? ClaudeUsageService.ServiceError {
                    claudeConsecutiveFailures = min(claudeConsecutiveFailures + 1, 9)
                    // 服务端给出明确 Retry-After 时以服务端为准,不再放大;
                    // 其余失败(尤其 PTY 探针超时)按连续次数翻倍退避。
                    let delay: TimeInterval
                    if case .rateLimited(let seconds) = serviceError, seconds != nil {
                        delay = serviceError.retryDelay
                    } else {
                        delay = AdaptiveRefreshPolicy.escalatedRetryDelay(
                            base: serviceError.retryDelay,
                            consecutiveFailures: claudeConsecutiveFailures
                        )
                    }
                    let retryAfter = now.addingTimeInterval(delay)
                    claudeRetryAfter = retryAfter
                    UserDefaults.standard.set(retryAfter, forKey: claudeRetryAfterKey)
                }
                logger.error("Claude quota refresh failed: \(error.localizedDescription, privacy: .public)")
                errors.append("Claude: \(error.localizedDescription)")
            }
            var systemState = providerAccountStates[.system(.claude)] ?? ProviderAccountState()
            systemState.notice = providerNotices[.claude]
            systemState.isRefreshing = false
            providerAccountStates[.system(.claude)] = systemState

        case .providerAccount(let profile, let accountResult):
            var state = providerAccountStates[profile.id] ?? ProviderAccountState()
            state.isRefreshing = false
            switch accountResult {
            case .success(let quota):
                state.quota = quota
                state.notice = nil
            case .failure(let error):
                // Preserve the last good reading and scope the failure to this
                // account; sibling accounts remain available.
                state.notice = error.localizedDescription
                errors.append("\(profile.displayName): \(error.localizedDescription)")
            }
            providerAccountStates[profile.id] = state

        case .codex(let codexResult):
            if codexAPIDue { lastCodexAPIAttempt = now }
            lastCodexLocalAttempt = now
            switch codexResult {
            case .success(let value):
                providerNotices[.codex] = nil
                sessionAlerts.reportHealthy(.codex)
                if localQuotas[.codex].map({
                    !Self.quotaRoutesMatch(value, $0) || value.capturedAt > $0.capturedAt
                }) ?? true {
                    assign(value, to: .codex)
                }
            case .failure(let error):
                if Self.invalidatesCachedQuota(error) {
                    assign(nil, to: .codex)
                }
                if codexAPIDue || codex == nil {
                    providerNotices[.codex] = error.localizedDescription
                    sessionAlerts.report(error: error, for: .codex, now: now)
                    errors.append("Codex: \(error.localizedDescription)")
                }
            }
            syncSystemAccountNotice(.codex)

        case .auxiliary(let provider, let auxResult):
            lastAuxProviderAttempts[provider] = now
            switch auxResult {
            case .success:
                auxProviderFailureCounts[provider] = nil
                auxProviderRetryAfter[provider] = nil
            case .failure:
                let failures = min((auxProviderFailureCounts[provider] ?? 0) + 1, 9)
                auxProviderFailureCounts[provider] = failures
                auxProviderRetryAfter[provider] = now.addingTimeInterval(
                    AdaptiveRefreshPolicy.retryDelay(after: failures)
                )
            }
            apply(auxResult, to: provider) { self.assign($0, to: provider) }
            syncSystemAccountNotice(provider)

        case .serviceStatuses(let statuses):
            lastServiceStatusAttempt = now
            for (provider, status) in statuses {
                serviceStatuses[provider] = status
            }
        }
    }

    /// Refreshes only the bundled ccusage snapshot. Presentation surfaces use
    /// this entry point so showing local totals does not also trigger network
    /// provider requests.
    func refreshLocalUsage(force: Bool = true) {
        scheduleCCUsageRefresh(force: force)
    }

    private func scheduleCCUsageRefresh(force: Bool, now: Date = .now) {
        guard historyRefreshTask == nil else { return }
        let interval = AdaptiveRefreshPolicy.localUsageInterval(
            preferred: PreferencesStore.shared.refreshInterval,
            lowLatencySyncEnabled: lowLatencySyncEnabled,
            localUsageUIVisible: localUsageUIVisibilityProvider?() ?? false,
            localSessionActive: sessionActivityMonitor.hasRecentSessionActivity(at: now)
        )
        guard AdaptiveRefreshPolicy.localUsageRefreshIsDue(
            interval: interval,
            lastRefresh: lastCCUsageRefresh,
            now: now,
            force: force
        ) else { return }
        lastCCUsageRefresh = now
        isCCUsageRefreshing = true

        historyRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isCCUsageRefreshing = false
                historyRefreshTask = nil
                publishErrors()
            }
            var merged: LocalUsageSnapshot?
            var errors: [String] = []
            do {
                merged = try await CCUsageService().fetchSnapshot(days: 30, now: now)
            } catch {
                errors.append("ccusage: \(error.localizedDescription)")
            }

            let traeDirectories = traeAgentDirectories
            let ccusageAlreadyIncludesTrae = merged.map { snapshot in
                snapshot.daily.agents.contains { $0.id == TraeAgentUsageService.agentID }
                    || snapshot.history.days.contains { day in
                        day.agents.contains { $0.id == TraeAgentUsageService.agentID }
                    }
            } == true
            if !traeDirectories.isEmpty, !ccusageAlreadyIncludesTrae {
                let trae = await TraeAgentUsageService(
                    directories: traeDirectories
                ).fetchSnapshot(days: 30, now: now)
                merged = merged.map { $0.merging(trae) } ?? trae
            }

            if let merged {
                latestLocalUsageSnapshot = merged
                applyLocalUsageSnapshot(merged)
            } else if daily == nil {
                localUsageStatus = .failed(errors.joined(separator: "\n"))
            }
            historyErrorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        }
    }

    private func applyLocalUsageSnapshot(_ snapshot: LocalUsageSnapshot) {
        let discovered = snapshot.daily.agents.map(\.id)
            + snapshot.history.days.flatMap(\.agents).map(\.id)
        discoveredLocalUsageSourceIDs.formUnion(
            discovered
                .map(LocalUsageSourceCatalog.canonicalID)
                .filter(LocalUsageSourceCatalog.isWellFormed)
        )
        if !traeAgentDirectories.isEmpty {
            discoveredLocalUsageSourceIDs.insert(TraeAgentUsageService.agentID)
        }

        let visibleDaily = DailyUsage(
            date: snapshot.daily.date,
            agents: snapshot.daily.agents.filter {
                isLocalUsageSourceEnabled($0.id)
            },
            capturedAt: snapshot.daily.capturedAt
        )
        let visibleHistory = DailyUsageHistory(
            days: snapshot.history.days.map { day in
                DailyUsageHistory.Day(
                    date: day.date,
                    agents: day.agents.filter { isLocalUsageSourceEnabled($0.id) }
                )
            },
            capturedAt: snapshot.history.capturedAt
        )
        daily = visibleDaily
        history = visibleHistory
        historyCache.save(visibleHistory)
        localUsageStatus = Self.localUsageStatus(for: visibleDaily)
    }

    private func reloadTraeAgentDirectories() {
        traeAgentDirectories = traeAgentTrajectoryStore.availableDirectories
        if !traeAgentDirectories.isEmpty {
            discoveredLocalUsageSourceIDs.insert(TraeAgentUsageService.agentID)
        }
    }

    private func publishErrors() {
        let combined = [quotaErrorMessage, historyErrorMessage]
            .compactMap { $0 }
            .joined(separator: "\n")
        errorMessage = combined.isEmpty ? nil : combined
    }

    nonisolated private static func supportsPastedCredential(
        _ provider: ProviderQuota.Provider
    ) -> Bool {
        provider == .zai
            || provider == .openrouter
            || ProviderSecretStore.descriptor(for: provider) != nil
    }

    private func storedCredentialStatus(
        for provider: ProviderQuota.Provider
    ) -> StoredCredentialStatus {
        switch provider {
        case .zai:
            return ZAIKeyStore().credentialStatus()
        case .openrouter:
            return OpenRouterKeyStore().credentialStatus()
        default:
            return ProviderSecretStore(provider: provider).credentialStatus()
        }
    }

    private func storedCredentialReadIssue(
        for provider: ProviderQuota.Provider
    ) -> String? {
        guard Self.supportsPastedCredential(provider) else { return nil }
        switch storedCredentialStatus(for: provider) {
        case .authorizationRequired:
            return L10n.text("datasource.credential_authorization_required")
        case .failed:
            return L10n.text("datasource.credential_read_failed")
        case .missing, .available:
            return nil
        }
    }

    private func storedPastedCredential(
        for provider: ProviderQuota.Provider,
        interaction: KeychainRead.Interaction
    ) throws -> String? {
        switch provider {
        case .zai:
            return try ZAIKeyStore().loadFromKeychain(interaction: interaction)
        case .openrouter:
            return try OpenRouterKeyStore().loadFromKeychain(interaction: interaction)
        default:
            guard ProviderSecretStore.descriptor(for: provider) != nil else { return nil }
            return try ProviderSecretStore(provider: provider)
                .loadFromKeychain(interaction: interaction)
        }
    }

    /// Fetches only with the submitted credential. No environment variable,
    /// config file, IPC session, or pre-existing Keychain item may satisfy this
    /// validation request on behalf of the value the user is replacing.
    private func fetchQuota(
        for provider: ProviderQuota.Provider,
        credential: String,
        now: Date
    ) async throws -> ProviderQuota {
        switch provider {
        case .zai:
            return try await ZAIUsageService().fetch(
                apiKey: credential,
                region: ZAIRegionStore().load(),
                now: now
            )
        case .openrouter:
            return try await OpenRouterUsageService().fetch(apiKey: credential, now: now)
        case .deepseek:
            return try await DeepSeekUsageService().fetch(apiKey: credential, now: now)
        case .kimi:
            return try await KimiUsageService().fetch(secret: credential, now: now)
        case .minimax:
            return try await MiniMaxUsageService().fetch(apiKey: credential, now: now)
        case .mimo:
            return try await MiMoUsageService().fetch(cookie: credential, now: now)
        case .qoder:
            return try await QoderUsageService().fetch(cookie: credential, now: now)
        case .volcengine:
            return try await VolcengineUsageService().fetch(credentials: credential, now: now)
        case .ollama:
            return try await OllamaUsageService().fetch(cookie: credential, now: now)
        case .zaiTeam:
            return try await ZAITeamUsageService().fetch(configuration: credential, now: now)
        case .thirdParty:
            return try await ThirdPartyUsageService().fetch(configuration: credential, now: now)
        default:
            throw ProviderAccountFetchService.FetchError.unsupportedProvider(
                provider.displayName
            )
        }
    }

    /// 保存用户在「额度」卡或「数据源」页粘贴的凭据(入钥匙串),
    /// 随即直查一次。凭据可以是 API Key、Cookie 或 AK:SK 组合。
    @discardableResult
    func saveAPIKey(_ key: String, for provider: ProviderQuota.Provider) async -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, Self.supportsPastedCredential(provider) else { return false }
        providerNotices[provider] = nil
        do {
            // Validate against the selected provider before touching an older
            // Keychain item. This is essential when repairing a stale ACL,
            // because rebinding requires delete + add rather than an update.
            let quota = try await fetchQuota(
                for: provider,
                credential: normalized,
                now: .now
            )
            switch provider {
            case .zai: try ZAIKeyStore().save(normalized)
            case .openrouter: try OpenRouterKeyStore().save(normalized)
            default:
                try ProviderSecretStore(provider: provider).save(normalized)
            }
            assign(quota, to: provider)
            providerNotices[provider] = nil
            quotaCache.save(currentSnapshot())
            return true
        } catch {
            providerNotices[provider] = error.localizedDescription
            return false
        }
    }

    /// 清除钥匙串中的 Key。环境变量/配置文件来源不受影响,
    /// 若仍存在会在下一轮刷新时继续生效。
    @discardableResult
    func clearAPIKey(for provider: ProviderQuota.Provider) async -> Bool {
        guard Self.supportsPastedCredential(provider) else { return false }
        do {
            switch provider {
            case .zai: try ZAIKeyStore().clear()
            case .openrouter: try OpenRouterKeyStore().clear()
            default: try ProviderSecretStore(provider: provider).clear()
            }
        } catch {
            providerNotices[provider] = error.localizedDescription
            return false
        }
        await refreshKeyProvider(provider)
        return true
    }

    /// Region selection is non-secret account metadata. Persist it separately
    /// from the API key and immediately re-query the same single Z.ai account.
    func setZAIRegion(_ region: ZAIAPIRegion) async {
        ZAIRegionStore().save(region)
        await refreshKeyProvider(.zai)
    }

    /// 由数据源页的明确用户操作触发。与后台刷新不同，这条路径允许 macOS
    /// 显示一次钥匙串访问确认；仍然只读凭证，不刷新、不写回 token。
    @discardableResult
    func authorizeProviderCredentials(_ provider: ProviderQuota.Provider) async -> Bool {
        let now = Date()
        do {
            let quota: ProviderQuota
            switch provider {
            case .claude:
                lastClaudeAttempt = now
                if hostQuotaRouter.route(for: .claude).isExternal {
                    quota = try await hostQuotaRouter.fetchClaude()
                } else {
                    quota = try await ClaudeOAuthUsageService().fetch(
                        now: now,
                        keychainInteraction: .allowed
                    )
                }
                claudeRetryAfter = nil
                claudeConsecutiveFailures = 0
                UserDefaults.standard.removeObject(forKey: claudeRetryAfterKey)
            case .codex:
                lastCodexAPIAttempt = now
                if hostQuotaRouter.route(for: .codex).isExternal {
                    quota = try await hostQuotaRouter.fetchCodex(preferAPI: true)
                } else {
                    quota = try await CodexAPIUsageService().fetch(
                        now: now,
                        keychainInteraction: .allowed
                    )
                }
            case .zai, .openrouter, .deepseek, .kimi, .minimax, .mimo,
                 .qoder, .volcengine, .ollama, .zaiTeam, .thirdParty:
                guard let credential = try storedPastedCredential(
                    for: provider,
                    interaction: .allowed
                ) else {
                    throw StoredCredentialActionError.missing(provider.displayName)
                }
                quota = try await fetchQuota(
                    for: provider,
                    credential: credential,
                    now: now
                )
                guard storedCredentialStatus(for: provider) == .available else {
                    throw StoredCredentialActionError.authorizationStillRequired
                }
            default:
                return false
            }

            assign(quota, to: provider)
            providerNotices[provider] = nil
            quotaCache.save(currentSnapshot())
            logger.info("Explicit read-only credential authorization succeeded for \(provider.rawValue, privacy: .public)")
            return true
        } catch {
            if Self.invalidatesCachedQuota(error) {
                assign(nil, to: provider)
                quotaCache.save(currentSnapshot())
            }
            providerNotices[provider] = error.localizedDescription
            logger.error("Explicit read-only credential authorization failed for \(provider.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func addClaudeAccount(displayName: String? = nil) async -> Bool {
        await addProviderAccount(provider: .claude, displayName: displayName, credential: nil)
    }

    /// Adds a managed account without publishing half-configured metadata.
    /// CLI providers complete official sign-in first; secret providers validate
    /// a device-only Keychain credential with a real quota request first.
    @discardableResult
    func addProviderAccount(
        provider: ProviderQuota.Provider,
        displayName: String? = nil,
        credential: String?
    ) async -> Bool {
        guard provider.multiAccountCapability != nil,
              !addingProviderAccounts.contains(provider) else { return false }
        addingProviderAccounts.insert(provider)
        accountManagementNotices[provider] = nil
        defer { addingProviderAccounts.remove(provider) }

        let profile: ProviderAccountProfile
        do {
            profile = try providerAccountsStore.prepareProfile(
                provider: provider,
                displayName: displayName
            )
        } catch {
            accountManagementNotices[provider] = error.localizedDescription
            return false
        }

        do {
            var initialQuota: ProviderQuota?
            switch profile.credentialKind {
            case .isolatedCLI:
                guard let path = profile.configurationDirectory else { return false }
                let directory = URL(fileURLWithPath: path)
                if provider == .claude {
                    try await ClaudeAccountLoginService().login(configurationDirectory: directory)
                } else if provider == .codex {
                    try await CodexAccountLoginService().login(configurationDirectory: directory)
                }
            case .keychainSecret:
                guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !credential.isEmpty else {
                    throw ProviderAccountFetchService.FetchError.missingCredential
                }
                initialQuota = try await ProviderAccountFetchService().fetch(
                    profile,
                    credentialOverride: credential
                )
                try ProviderAccountSecretStore(
                    provider: provider,
                    accountID: profile.id
                ).save(credential)
            case nil:
                throw ProviderAccountFetchService.FetchError.unsupportedProvider(provider.displayName)
            }
            providerAccountsStore.commit(profile)
            providerAccountProfiles = providerAccountsStore.allProfiles
            providerAccountsStore.setSelection(.account(profile.id), for: provider)
            providerAccountSelections = providerAccountsStore.selections
            providerAccountStates[profile.id] = ProviderAccountState(
                quota: initialQuota,
                isRefreshing: initialQuota == nil
            )
            if initialQuota != nil {
                providerAccountQuotaCache.save(currentProviderAccountQuotas())
                return true
            }
            await refreshProviderAccount(profile.id)
            return providerAccountStates[profile.id]?.quota != nil
        } catch {
            try? ProviderAccountSecretStore(
                provider: provider,
                accountID: profile.id
            ).delete()
            providerAccountsStore.discardPreparedProfile(profile)
            accountManagementNotices[provider] = error.localizedDescription
            return false
        }
    }

    func renameProviderAccount(_ id: ProviderAccountID, to displayName: String) {
        providerAccountsStore.rename(id, to: displayName)
        providerAccountProfiles = providerAccountsStore.allProfiles
    }

    /// Replaces a managed account credential only after the provider accepts
    /// it. The previous Keychain item remains untouched when validation fails.
    @discardableResult
    func updateProviderAccountCredential(
        _ id: ProviderAccountID,
        credential: String
    ) async -> Bool {
        guard let profile = providerAccountProfiles.first(where: { $0.id == id }),
              profile.kind == .managed,
              profile.credentialKind == .keychainSecret else { return false }
        let normalized = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        accountManagementNotices[profile.provider] = nil
        var state = providerAccountStates[id] ?? ProviderAccountState()
        state.isRefreshing = true
        providerAccountStates[id] = state
        do {
            let quota = try await ProviderAccountFetchService().fetch(
                profile,
                credentialOverride: normalized
            )
            try ProviderAccountSecretStore(
                provider: profile.provider,
                accountID: profile.id
            ).save(normalized)
            state.quota = quota
            state.notice = nil
            state.isRefreshing = false
            providerAccountStates[id] = state
            providerAccountQuotaCache.save(currentProviderAccountQuotas())
            return true
        } catch {
            state.isRefreshing = false
            state.notice = error.localizedDescription
            providerAccountStates[id] = state
            accountManagementNotices[profile.provider] = error.localizedDescription
            return false
        }
    }

    func setProviderAccountEnabled(_ enabled: Bool, id: ProviderAccountID) {
        providerAccountsStore.setEnabled(enabled, for: id)
        providerAccountProfiles = providerAccountsStore.allProfiles
        if enabled {
            Task { await refreshProviderAccount(id) }
        } else {
            var state = providerAccountStates[id] ?? ProviderAccountState()
            state.isRefreshing = false
            providerAccountStates[id] = state
        }
    }

    func removeProviderAccount(_ id: ProviderAccountID) {
        guard !id.rawValue.hasPrefix("system."), providerAccountsStore.remove(id) != nil else { return }
        providerAccountProfiles = providerAccountsStore.allProfiles
        providerAccountSelections = providerAccountsStore.selections
        providerAccountStates[id] = nil
        providerAccountQuotaCache.save(currentProviderAccountQuotas())
    }

    func refreshProviderAccount(_ id: ProviderAccountID) async {
        guard let profile = providerAccountProfiles.first(where: { $0.id == id }),
              profile.isEnabled else { return }
        if profile.isSystem {
            switch profile.provider {
            case .claude:
                await refresh(forceCCUsage: false, forceClaude: true)
            case .codex:
                let result = await result {
                    try await self.hostQuotaRouter.fetchCodex(preferAPI: true)
                }
                var errors: [String] = []
                applyQuotaRefreshOutput(
                    .codex(result),
                    attemptedAt: .now,
                    codexAPIDue: true,
                    errors: &errors
                )
            default:
                await refreshKeyProvider(profile.provider)
            }
            return
        }
        var state = providerAccountStates[id] ?? ProviderAccountState()
        state.isRefreshing = true
        providerAccountStates[id] = state
        do {
            state.quota = try await ProviderAccountFetchService().fetch(profile)
            state.notice = nil
        } catch {
            state.notice = error.localizedDescription
        }
        state.isRefreshing = false
        providerAccountStates[id] = state
        providerAccountQuotaCache.save(currentProviderAccountQuotas())
    }

    private func refreshKeyProvider(_ provider: ProviderQuota.Provider) async {
        let results = await Self.fetchAux(providers: [provider])
        guard let fetchResult = results[provider] else { return }
        apply(fetchResult, to: provider) { self.assign($0, to: provider) }
        if case .failure = fetchResult,
           storedCredentialReadIssue(for: provider) == nil {
            // Key 被清空后旧数据已无意义,不再展示。
            assign(nil, to: provider)
        }
        quotaCache.save(currentSnapshot())
    }

    private func apply(
        _ result: Result<ProviderQuota, Error>?,
        to provider: ProviderQuota.Provider,
        assign: (ProviderQuota) -> Void
    ) {
        guard let result else { return }
        switch result {
        case .success(let value):
            assign(value)
            providerNotices[provider] = nil
        case .failure(let error):
            let credentialIssue = storedCredentialReadIssue(for: provider)
            if credentialIssue == nil, Self.invalidatesCachedQuota(error) {
                self.assign(nil, to: provider)
            }
            providerNotices[provider] = credentialIssue ?? error.localizedDescription
        }
    }

    private func syncSystemAccountNotice(_ provider: ProviderQuota.Provider) {
        let id = ProviderAccountID.system(provider)
        guard providerAccountProfiles.contains(where: { $0.id == id }) else { return }
        var state = providerAccountStates[id] ?? ProviderAccountState()
        state.notice = providerNotices[provider]
        state.isRefreshing = false
        providerAccountStates[id] = state
    }

    private func currentSnapshot() -> QuotaCache.Snapshot {
        .init(byProvider: localQuotas)
    }

    /// Applies an already authenticated and replay-checked direct-sync value.
    /// The freshest reading wins independently per provider; local cache and
    /// outbound Mac snapshots continue to contain only Mac-produced readings.
    func applyDirectSyncSnapshot(_ snapshot: MobileUsageSnapshot) {
        directSyncSnapshots[snapshot.sourceInstanceID] = snapshot
        for provider in DirectSyncSnapshotAdapter.quotas(from: snapshot).keys {
            tracked.markConnected(provider)
        }
        recomputeEffectiveQuotas()
    }

    var localQuotasForDirectSync: [ProviderQuota.Provider: ProviderQuota] {
        localQuotas
    }

    private func recomputeEffectiveQuotas(now: Date = Date()) {
        directSyncSnapshots = directSyncSnapshots.filter { $0.value.expiresAt >= now }
        var merged = localQuotas.filter { tracked.isEnabled($0.key) }
        for snapshot in directSyncSnapshots.values {
            for (provider, quota) in DirectSyncSnapshotAdapter.quotas(from: snapshot)
            where tracked.isEnabled(provider) {
                if merged[provider].map({ quota.capturedAt > $0.capturedAt }) ?? true {
                    merged[provider] = quota
                }
            }
        }
        quotas = merged
    }

    private func currentProviderAccountQuotas() -> [ProviderAccountID: ProviderQuota] {
        Dictionary(uniqueKeysWithValues: providerAccountStates.compactMap { id, state in
            guard !id.rawValue.hasPrefix("system."), let quota = state.quota else { return nil }
            return (id, quota)
        })
    }

    nonisolated static func shouldRefreshCodex(
        enabled: Bool,
        routeIsExternal: Bool,
        apiDue: Bool,
        localSnapshotDue: Bool
    ) -> Bool {
        enabled && (apiDue || (!routeIsExternal && localSnapshotDue))
    }

    nonisolated static func invalidatesCachedQuota(_ error: Error) -> Bool {
        error is HostAppQuotaRoutingError
    }

    deinit {
        refreshTask?.cancel()
        historyRefreshTask?.cancel()
    }

    private func remainingText(for quota: ProviderQuota?) -> String {
        guard let quota else { return "—" }
        let summary = quota.generalQuotaSummary(
            strategy: PreferencesStore.shared.quotaSummaryStrategy
        )
        return summary.remainingBalance?.displayText
            ?? UsageFormatting.percent(summary.remainingPercent)
    }
}

private func result<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}
