import Foundation
import OSLog

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var claude: ProviderQuota?
    @Published private(set) var codex: ProviderQuota?
    @Published private(set) var daily: DailyUsage?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private var refreshTask: Task<Void, Never>?
    private var lastCCUsageRefresh: Date?
    private var lastClaudeAttempt: Date?
    private var claudeRetryAfter: Date?
    private let quotaCache = QuotaCache()
    private let logger = Logger(subsystem: "com.jamesli.usagedock", category: "UsageRefresh")
    private let claudeRetryAfterKey = "claudeRetryAfter"

    var claudeRemainingText: String {
        remainingText(for: claude)
    }

    var codexRemainingText: String {
        remainingText(for: codex)
    }

    init() {
        if let cached = quotaCache.load() {
            claude = cached.claude
            codex = cached.codex
            lastClaudeAttempt = cached.claude?.capturedAt
        }
        claudeRetryAfter = UserDefaults.standard.object(forKey: claudeRetryAfterKey) as? Date
        Task { @MainActor [weak self] in
            self?.start()
        }
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
        let shouldRefreshClaude = forceClaude || normalClaudeRefreshDue || backoffJustCompleted

        async let claudeResult: Result<ProviderQuota, Error>? = shouldRefreshClaude
            ? result { try await ClaudeUsageService().fetch() }
            : nil
        async let codexResult = result { try await CodexUsageService().fetch() }
        let quotaResults = await (claudeResult, codexResult)
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
        switch quotaResults.1 {
        case .success(let value):
            codex = value
        case .failure(let error): errors.append("Codex: \(error.localizedDescription)")
        }

        quotaCache.save(.init(claude: claude, codex: codex))

        let shouldRefreshCCUsage = forceCCUsage || lastCCUsageRefresh.map { Date().timeIntervalSince($0) >= 300 } != false
        if shouldRefreshCCUsage {
            do {
                daily = try await CCUsageService().fetch()
                lastCCUsageRefresh = .now
            } catch {
                errors.append("ccusage: \(error.localizedDescription)")
            }
        }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
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
