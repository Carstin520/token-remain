import Combine
import Foundation
import OSLog

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

    /// 各 provider 当前快照的唯一存储。逐 provider 的具名访问器保留在下方,
    /// 视图无需感知字典结构。
    @Published private(set) var quotas: [ProviderQuota.Provider: ProviderQuota] = [:]

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
    private let traeAgentTrajectoryStore: TraeAgentTrajectoryStore
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var lastCCUsageRefresh: Date?
    private var lastClaudeAttempt: Date?
    private var lastCodexAPIAttempt: Date?
    private var lastServiceStatusAttempt: Date?
    private var lastAuxProviderAttempts: [ProviderQuota.Provider: Date] = [:]
    private var auxProviderFailureCounts: [ProviderQuota.Provider: Int] = [:]
    private var auxProviderRetryAfter: [ProviderQuota.Provider: Date] = [:]
    private var claudeRetryAfter: Date?
    private var lowLatencySyncEnabled = false
    /// 由状态栏控制器注入:本地用量正出现在任一可见界面(弹窗/仪表板/
    /// 浮窗)时返回 true。后台 ccusage 扫描据此决定是否维持分钟级节奏。
    var localUsageUIVisibilityProvider: (() -> Bool)?
    private let quotaCache = QuotaCache()
    private let historyCache = DailyHistoryCache()
    private let quotaUsageHistoryCache = QuotaUsageHistoryCache()
    private let logger = Logger(subsystem: "com.jamesli.usagedock", category: "UsageRefresh")
    private let claudeRetryAfterKey = "claudeRetryAfter"
    private let serviceStatusRefreshInterval: TimeInterval = 300
    private var quotaErrorMessage: String?
    private var historyErrorMessage: String?
    private var latestLocalUsageSnapshot: LocalUsageSnapshot?
    private let disabledLocalUsageSourcesKey = "tokenRemain.disabledLocalUsageSources.v1"

    private enum QuotaRefreshOutput {
        case claude(Result<ProviderQuota, Error>)
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
    static let auxProviders: [ProviderQuota.Provider] = [
        .cursor, .grok, .zai, .copilot, .devin, .windsurf,
        .openrouter, .antigravity, .opencode,
        .deepseek, .kimi, .minimax, .mimo, .qoder, .kiro, .volcengine, .ollama
    ]

    /// 当前全部 provider 快照(含未追踪的 nil),固定顺序。
    private var allQuotas: [ProviderQuota?] {
        TrackedProvidersStore.allProviders.map(quotaValue(for:))
    }

    var aggregateRemainingPercent: Double? {
        logoQuotaSelection?.remainingPercent
    }

    var logoQuotaSelection: LogoQuotaSelection? {
        Self.logoQuotaSelection(from: allQuotas)
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
        if value != nil {
            tracked.markConnected(provider)
        }
        quotas[provider] = value
        if let value {
            let updated = quotaUsageHistory.recording(value)
            if updated != quotaUsageHistory {
                quotaUsageHistory = updated
                quotaUsageHistoryCache.save(updated)
            }
        }
    }

    private static func auxFetcher(
        for provider: ProviderQuota.Provider
    ) -> (@Sendable () async throws -> ProviderQuota)? {
        switch provider {
        case .cursor: return { try await CursorUsageService().fetch() }
        case .grok: return { try await GrokUsageService().fetch() }
        case .zai: return { try await ZAIUsageService().fetch() }
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

    static func aggregateRemainingPercent(from quotas: [ProviderQuota?]) -> Double? {
        logoQuotaSelection(from: quotas)?.remainingPercent
    }

    /// Each provider contributes only its shortest recurring quota window to
    /// the app-logo comparison. This avoids comparing Claude's five-hour and
    /// seven-day windows against Codex's single seven-day window as if all
    /// three represented equivalent sessions.
    static func logoQuotaSelection(from quotas: [ProviderQuota?]) -> LogoQuotaSelection? {
        quotas.compactMap { quota -> LogoQuotaSelection? in
            guard let quota else { return nil }
            let windows = [quota.primary, quota.secondary].compactMap { $0 }
            guard let shortest = windows.min(by: { lhs, rhs in
                // A zero-minute window is a lifetime meter, not a session.
                // Keep it as a fallback only when the provider has no recurring window.
                let lhsDuration = lhs.windowMinutes > 0 ? lhs.windowMinutes : Int.max
                let rhsDuration = rhs.windowMinutes > 0 ? rhs.windowMinutes : Int.max
                return lhsDuration < rhsDuration
            }) else { return nil }

            return LogoQuotaSelection(
                provider: quota.provider,
                remainingPercent: min(max(100 - shortest.usedPercent, 0), 100),
                windowMinutes: shortest.windowMinutes
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
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.tracked = tracked
        self.defaults = defaults
        traeAgentTrajectoryStore = TraeAgentTrajectoryStore(defaults: defaults, home: home)
        disabledLocalUsageSourceIDs = Set(
            (defaults.stringArray(forKey: disabledLocalUsageSourcesKey) ?? [])
                .map(LocalUsageSourceCatalog.canonicalID)
                .filter(LocalUsageSourceCatalog.isWellFormed)
        )
        traeAgentDirectories = traeAgentTrajectoryStore.availableDirectories
        if let cached = quotaCache.load() {
            quotas = cached.byProvider
            // 升级兼容：旧版没有独立连接历史，已有成功快照就是最可靠的
            // “曾连接”证据。
            for provider in cached.byProvider.keys {
                tracked.markConnected(provider)
            }
            lastClaudeAttempt = cached.byProvider[.claude]?.capturedAt
        }
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
            var nextRefresh = clock.now
            var isInitialRefresh = true
            // A cached request timestamp must not make a freshly launched menu-bar app
            // display a completed countdown for another five minutes. The refresh method
            // still honors an active server-rate-limit backoff.
            while !Task.isCancelled {
                await self?.refresh(
                    forceCCUsage: isInitialRefresh,
                    forceClaude: isInitialRefresh
                )
                isInitialRefresh = false
                nextRefresh += .seconds(AdaptiveRefreshPolicy.activeInterval)
                if nextRefresh < clock.now {
                    nextRefresh = clock.now
                }
                try? await Task.sleep(until: nextRefresh, clock: clock)
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
        // 普通直查节奏由用户偏好决定；启用 Apple 设备同步后由低延迟
        // 策略临时覆盖，关闭同步即恢复原偏好。
        let interval = AdaptiveRefreshPolicy.interval(
            preferred: PreferencesStore.shared.refreshInterval,
            lowLatencySyncEnabled: lowLatencySyncEnabled
        )
        func autoDue(since date: Date?) -> Bool {
            guard let interval else { return false }
            return date.map { now.timeIntervalSince($0) >= interval } ?? true
        }
        let backoffJustCompleted = claudeRetryAfter.map { now >= $0 } ?? false
        let shouldRefreshClaude = tracked.isEnabled(.claude)
            && (forceClaude || autoDue(since: lastClaudeAttempt) || backoffJustCompleted)

        // Codex 本地会话快照保持分钟级扫描；API 直查遵循当前有效节奏，
        // 同步关闭时仍回到用户设置的刷新偏好。
        let codexAPIDue = forceClaude || autoDue(since: lastCodexAPIAttempt)

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
        let dueAuxProviders = Self.auxProviders.filter { provider in
            guard tracked.isEnabled(provider) else { return false }
            if forceClaude { return true }
            if let retryAfter = auxProviderRetryAfter[provider], now < retryAfter {
                return false
            }
            return autoDue(since: lastAuxProviderAttempts[provider])
        }

        var errors: [String] = []
        await withTaskGroup(of: QuotaRefreshOutput.self) { group in
            if shouldRefreshClaude {
                group.addTask {
                    .claude(await result { try await ClaudeUsageService().fetch() })
                }
            }
            if codexEnabled {
                group.addTask {
                    .codex(
                        await result {
                            try await CodexUsageService().fetch(preferAPI: codexAPIDue)
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
            }
        }

        quotaErrorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        publishErrors()
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
                UserDefaults.standard.removeObject(forKey: claudeRetryAfterKey)
                logger.info("Claude quota refreshed; primary usage: \(value.primary.usedPercent, privacy: .public)%, reset time available: \(value.primary.resetsAt != nil, privacy: .public)")
            case .failure(let error):
                providerNotices[.claude] = error.localizedDescription
                if let serviceError = error as? ClaudeUsageService.ServiceError {
                    let retryAfter = now.addingTimeInterval(serviceError.retryDelay)
                    claudeRetryAfter = retryAfter
                    UserDefaults.standard.set(retryAfter, forKey: claudeRetryAfterKey)
                }
                logger.error("Claude quota refresh failed: \(error.localizedDescription, privacy: .public)")
                errors.append("Claude: \(error.localizedDescription)")
            }

        case .codex(let codexResult):
            if codexAPIDue { lastCodexAPIAttempt = now }
            switch codexResult {
            case .success(let value):
                providerNotices[.codex] = nil
                if codex.map({ value.capturedAt > $0.capturedAt }) ?? true {
                    assign(value, to: .codex)
                }
            case .failure(let error):
                if codexAPIDue || codex == nil {
                    providerNotices[.codex] = error.localizedDescription
                    errors.append("Codex: \(error.localizedDescription)")
                }
            }

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
            localUsageUIVisible: localUsageUIVisibilityProvider?() ?? false
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

    /// 保存用户在「数据源」页粘贴的 API Key(入钥匙串),随即直查一次。
    /// 仅 Z.ai / OpenRouter 这类无本地凭证的 provider 需要。
    func saveAPIKey(_ key: String, for provider: ProviderQuota.Provider) async {
        do {
            switch provider {
            case .zai: try ZAIKeyStore().save(key)
            case .openrouter: try OpenRouterKeyStore().save(key)
            default:
                guard ProviderSecretStore.descriptor(for: provider) != nil else { return }
                try ProviderSecretStore(provider: provider).save(key)
            }
        } catch {
            providerNotices[provider] = error.localizedDescription
            return
        }
        await refreshKeyProvider(provider)
    }

    /// 清除钥匙串中的 Key。环境变量/配置文件来源不受影响,
    /// 若仍存在会在下一轮刷新时继续生效。
    func clearAPIKey(for provider: ProviderQuota.Provider) async {
        switch provider {
        case .zai: try? ZAIKeyStore().clear()
        case .openrouter: try? OpenRouterKeyStore().clear()
        default:
            guard ProviderSecretStore.descriptor(for: provider) != nil else { return }
            try? ProviderSecretStore(provider: provider).clear()
        }
        await refreshKeyProvider(provider)
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
                quota = try await ClaudeOAuthUsageService().fetch(
                    now: now,
                    keychainInteraction: .allowed
                )
                claudeRetryAfter = nil
                UserDefaults.standard.removeObject(forKey: claudeRetryAfterKey)
            case .codex:
                lastCodexAPIAttempt = now
                quota = try await CodexAPIUsageService().fetch(
                    now: now,
                    keychainInteraction: .allowed
                )
            default:
                return false
            }

            assign(quota, to: provider)
            providerNotices[provider] = nil
            quotaCache.save(currentSnapshot())
            logger.info("Explicit read-only credential authorization succeeded for \(provider.rawValue, privacy: .public)")
            return true
        } catch {
            providerNotices[provider] = error.localizedDescription
            logger.error("Explicit read-only credential authorization failed for \(provider.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func refreshKeyProvider(_ provider: ProviderQuota.Provider) async {
        let results = await Self.fetchAux(providers: [provider])
        guard let fetchResult = results[provider] else { return }
        apply(fetchResult, to: provider) { self.assign($0, to: provider) }
        if case .failure = fetchResult {
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
            providerNotices[provider] = error.localizedDescription
        }
    }

    private func currentSnapshot() -> QuotaCache.Snapshot {
        .init(byProvider: quotas)
    }

    deinit {
        refreshTask?.cancel()
        historyRefreshTask?.cancel()
    }

    private func remainingText(for quota: ProviderQuota?) -> String {
        guard let quota else { return "—" }
        return UsageFormatting.percent(max(0, 100 - quota.primary.usedPercent))
    }
}

private func result<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}
