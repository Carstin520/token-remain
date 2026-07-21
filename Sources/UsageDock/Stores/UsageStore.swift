import Combine
import Foundation
import OSLog

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var claude: ProviderQuota?
    @Published private(set) var codex: ProviderQuota?
    @Published private(set) var cursor: ProviderQuota?
    @Published private(set) var grok: ProviderQuota?
    @Published private(set) var zai: ProviderQuota?
    @Published private(set) var copilot: ProviderQuota?
    @Published private(set) var devin: ProviderQuota?
    @Published private(set) var openrouter: ProviderQuota?
    @Published private(set) var antigravity: ProviderQuota?
    @Published private(set) var opencode: ProviderQuota?
    /// 直查 provider 卡片内的状态说明(未接入指引、登录过期提示等)。
    /// 刻意不进全局错误条:"未接入某工具"是卡片语境的信息,
    /// 不该像故障一样反复告警。
    @Published private(set) var providerNotices: [ProviderQuota.Provider: String] = [:]
    @Published private(set) var daily: DailyUsage?
    @Published private(set) var history: DailyUsageHistory?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let tracked: TrackedProvidersStore
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var lastCCUsageRefresh: Date?
    private var lastClaudeAttempt: Date?
    private var lastCodexAPIAttempt: Date?
    /// Cursor / Grok / Z.ai 共用的直查节奏门(它们都只有 API 一条路)。
    private var lastAuxProvidersAttempt: Date?
    private var claudeRetryAfter: Date?
    private let quotaCache = QuotaCache()
    private let historyCache = DailyHistoryCache()
    private let logger = Logger(subsystem: "com.jamesli.usagedock", category: "UsageRefresh")
    private let claudeRetryAfterKey = "claudeRetryAfter"

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
        .cursor, .grok, .zai, .copilot, .devin, .openrouter, .antigravity, .opencode
    ]

    /// 当前全部 provider 快照(含未追踪的 nil),固定顺序。
    private var allQuotas: [ProviderQuota?] {
        TrackedProvidersStore.allProviders.map(quotaValue(for:))
    }

    var aggregateRemainingPercent: Double? {
        Self.aggregateRemainingPercent(from: allQuotas)
    }

    func quotaValue(for provider: ProviderQuota.Provider) -> ProviderQuota? {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        case .cursor: return cursor
        case .grok: return grok
        case .zai: return zai
        case .copilot: return copilot
        case .devin: return devin
        case .openrouter: return openrouter
        case .antigravity: return antigravity
        case .opencode: return opencode
        }
    }

    private func assign(_ value: ProviderQuota?, to provider: ProviderQuota.Provider) {
        switch provider {
        case .claude: claude = value
        case .codex: codex = value
        case .cursor: cursor = value
        case .grok: grok = value
        case .zai: zai = value
        case .copilot: copilot = value
        case .devin: devin = value
        case .openrouter: openrouter = value
        case .antigravity: antigravity = value
        case .opencode: opencode = value
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
        case .openrouter: return { try await OpenRouterUsageService().fetch() }
        case .antigravity: return { try await AntigravityUsageService().fetch() }
        case .opencode: return { try await OpenCodeUsageService().fetch() }
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
        let values = quotas.compactMap { $0 }.flatMap { quota in
            [quota.primary, quota.secondary].compactMap { $0 }.map { window in
                min(max(100 - window.usedPercent, 0), 100)
            }
        }
        return values.min()
    }

    convenience init() {
        self.init(tracked: TrackedProvidersStore.shared)
    }

    init(tracked: TrackedProvidersStore) {
        self.tracked = tracked
        if let cached = quotaCache.load() {
            claude = cached.claude
            codex = cached.codex
            cursor = cached.cursor
            grok = cached.grok
            zai = cached.zai
            copilot = cached.copilot
            devin = cached.devin
            openrouter = cached.openrouter
            antigravity = cached.antigravity
            opencode = cached.opencode
            lastClaudeAttempt = cached.claude?.capturedAt
        }
        history = historyCache.load()
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
        quotaCache.save(currentSnapshot())
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            // A cached request timestamp must not make a freshly launched menu-bar app
            // display a completed countdown for another five minutes. The refresh method
            // still honors an active server-rate-limit backoff.
            await self?.refresh(forceCCUsage: true, forceClaude: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refresh(forceCCUsage: false)
            }
        }
    }

    func refresh(forceCCUsage: Bool = true, forceClaude: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        let normalClaudeRefreshDue = lastClaudeAttempt.map { now.timeIntervalSince($0) >= 300 } ?? true
        let backoffJustCompleted = claudeRetryAfter.map { now >= $0 } ?? false
        let shouldRefreshClaude = tracked.isEnabled(.claude)
            && (forceClaude || normalClaudeRefreshDue || backoffJustCompleted)

        // Codex API 直查限到 5 分钟一次(手动刷新立即直查);分钟级轮次
        // 只扫本地会话快照,在两次直查之间补新而不打服务端接口。
        let codexAPIDue = forceClaude || lastCodexAPIAttempt.map { now.timeIntervalSince($0) >= 300 } ?? true

        // Cursor / Grok / Z.ai 只有 API 一条路(无本地快照可扫),
        // 与 Claude 同为 5 分钟节奏。
        let auxDue = forceClaude || lastAuxProvidersAttempt.map { now.timeIntervalSince($0) >= 300 } ?? true

        // async-let 的子任务不在主 actor 上,启用判断先在这里(主 actor)取好。
        let codexEnabled = tracked.isEnabled(.codex)
        let dueAuxProviders = auxDue ? Self.auxProviders.filter(tracked.isEnabled) : []

        async let claudeResult: Result<ProviderQuota, Error>? = shouldRefreshClaude
            ? result { try await ClaudeUsageService().fetch() }
            : nil
        async let codexResult: Result<ProviderQuota, Error>? = codexEnabled
            ? result { try await CodexUsageService().fetch(preferAPI: codexAPIDue) }
            : nil
        async let auxResults = Self.fetchAux(providers: dueAuxProviders)
        let quotaResults = await (claudeResult, codexResult, auxResults)
        var errors: [String] = []

        if let claudeResult = quotaResults.0 {
            lastClaudeAttempt = now
            switch claudeResult {
            case .success(let value):
                claude = value
                claudeRetryAfter = nil
                UserDefaults.standard.removeObject(forKey: claudeRetryAfterKey)
                logger.info("Claude quota refreshed; primary usage: \(value.primary.usedPercent, privacy: .public)%, reset time available: \(value.primary.resetsAt != nil, privacy: .public)")
            case .failure(let error):
                if let serviceError = error as? ClaudeUsageService.ServiceError {
                    let retryAfter = now.addingTimeInterval(serviceError.retryDelay)
                    claudeRetryAfter = retryAfter
                    UserDefaults.standard.set(retryAfter, forKey: claudeRetryAfterKey)
                }
                logger.error("Claude quota refresh failed: \(error.localizedDescription, privacy: .public)")
                errors.append("Claude: \(error.localizedDescription)")
            }
        }
        if codexAPIDue { lastCodexAPIAttempt = now }
        if let codexResult = quotaResults.1 {
            switch codexResult {
            case .success(let value):
                // 快照补新绝不把界面回退到比当前更旧的数据;API 结果的
                // capturedAt 是请求时刻,天然通过该检查。
                if codex.map({ value.capturedAt > $0.capturedAt }) ?? true {
                    codex = value
                }
            case .failure(let error):
                // 快照缺失对纯 API 用户是常态:间隙轮次失败且已有数据时不算错误。
                if codexAPIDue || codex == nil {
                    errors.append("Codex: \(error.localizedDescription)")
                }
            }
        }

        if auxDue {
            lastAuxProvidersAttempt = now
            // 缓存数据继续展示;说明文字告诉用户为什么没有数据、怎么接入/恢复。
            for provider in Self.auxProviders {
                guard let auxResult = quotaResults.2[provider] else { continue }
                apply(auxResult, to: provider) { self.assign($0, to: provider) }
            }
        }

        quotaCache.save(currentSnapshot())

        let shouldRefreshCCUsage = forceCCUsage || lastCCUsageRefresh.map { Date().timeIntervalSince($0) >= 300 } != false
        if shouldRefreshCCUsage {
            do {
                daily = try await CCUsageService().fetch()
                lastCCUsageRefresh = .now
            } catch {
                errors.append("ccusage: \(error.localizedDescription)")
            }
            do {
                let fetched = try await CCUsageService().fetchHistory(days: 30)
                history = fetched
                historyCache.save(fetched)
            } catch {
                errors.append("ccusage 历史: \(error.localizedDescription)")
            }
        }

        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// 保存用户在「数据源」页粘贴的 API Key(入钥匙串),随即直查一次。
    /// 仅 Z.ai / OpenRouter 这类无本地凭证的 provider 需要。
    func saveAPIKey(_ key: String, for provider: ProviderQuota.Provider) async {
        do {
            switch provider {
            case .zai: try ZAIKeyStore().save(key)
            case .openrouter: try OpenRouterKeyStore().save(key)
            default: return
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
        default: return
        }
        await refreshKeyProvider(provider)
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
        .init(
            claude: claude, codex: codex, cursor: cursor, grok: grok, zai: zai,
            copilot: copilot, devin: devin, openrouter: openrouter,
            antigravity: antigravity, opencode: opencode
        )
    }

    deinit { refreshTask?.cancel() }

    private func remainingText(for quota: ProviderQuota?) -> String {
        guard let quota else { return "—" }
        return UsageFormatting.percent(max(0, 100 - quota.primary.usedPercent))
    }
}

private func result<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}
