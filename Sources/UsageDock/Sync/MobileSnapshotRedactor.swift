import Foundation
import TokenRemainSyncKit

/// The only path from macOS provider models into the cross-device payload.
/// Keep this conversion explicit: adding fields to `ProviderQuota` must never
/// make them cross devices automatically.
enum MobileSnapshotRedactor {
    static let maximumLifetime: TimeInterval = 24 * 60 * 60

    /// Every quota provider rendered by the current phone client. This list is
    /// presentation-independent and remains an explicit privacy boundary: only
    /// normalized quota windows, timestamps, source state and a sanitized plan
    /// label cross devices; credentials and raw provider responses never do.
    static let publishedProviders: [ProviderQuota.Provider] = ProviderQuota.Provider.displayOrder.filter {
        SyncedProviderID.supportedOnCurrentMobile.contains(stableID(for: $0))
    }

    /// Days, counting today, whose per-model rows are offered before the
    /// payload budget trims them further.
    static let modelDetailDays = 7

    static func makeSnapshot(
        from quotas: [ProviderQuota.Provider: ProviderQuota],
        history: DailyUsageHistory? = nil,
        includesUsageHistory: Bool = false,
        throughput: ModelThroughputSnapshot = .empty,
        sourceInstanceID: UUID,
        sequence: UInt64,
        generatedAt: Date = Date()
    ) -> MobileUsageSnapshot {
        let providers = publishedProviders.compactMap { provider in
            quotas[provider].map(redact)
        }
        func snapshot(_ history: SyncedDailyUsageHistory?) -> MobileUsageSnapshot {
            MobileUsageSnapshot(
                sourceInstanceID: sourceInstanceID,
                sequence: sequence,
                generatedAt: generatedAt,
                expiresAt: generatedAt.addingTimeInterval(maximumLifetime),
                providers: providers,
                aggregateUsage: nil,
                dailyUsageHistory: history,
                curatedFeed: nil
            )
        }

        guard includesUsageHistory, let history else { return snapshot(nil) }
        let redacted = redactedHistory(history, throughput: throughput, now: generatedAt)
        return snapshot(fitted(redacted) { snapshot($0) })
    }

    /// Trims optional detail until the encoded payload fits the envelope that
    /// every receiver — including iPhones and Windows builds that predate the
    /// detail — enforces. Order: model rows from the oldest day forward, then
    /// per-agent rows, then the day mix. The legacy columns and the quota
    /// snapshot are never trimmed, so an over-budget Mac still publishes what
    /// it published before the detail existed.
    static func fitted(
        _ history: SyncedDailyUsageHistory,
        budget: Int = EncryptedSyncEnvelope.maximumPlaintextBytes,
        in snapshot: (SyncedDailyUsageHistory) -> MobileUsageSnapshot
    ) -> SyncedDailyUsageHistory {
        func rebuilt(_ days: [SyncedDailyUsageDay]) -> SyncedDailyUsageHistory {
            SyncedDailyUsageHistory(days: days, capturedAt: history.capturedAt, sourceDay: history.sourceDay)
        }
        func fits(_ days: [SyncedDailyUsageDay]) -> Bool {
            let built = snapshot(rebuilt(days))
            // `seal` validates first, which can only drop rows, then encodes.
            let measured = (try? built.validatedForTransport(
                configuration: .current(now: built.generatedAt)
            )) ?? built
            guard let payload = try? measured.encodedPayload() else { return false }
            return payload.count <= budget
        }
        let trims: [(SyncedDailyUsageDay) -> SyncedDailyUsageDay?] = [
            { day in
                guard day.agents?.contains(where: { $0.models != nil }) == true else { return nil }
                return SyncedDailyUsageDay(
                    day: day.day,
                    claudeTokens: day.claudeTokens,
                    claudeCost: day.claudeCost,
                    codexTokens: day.codexTokens,
                    codexCost: day.codexCost,
                    agents: day.agents?.map(\.withoutModels),
                    mix: day.mix
                )
            },
            { day in
                guard day.agents != nil else { return nil }
                return SyncedDailyUsageDay(
                    day: day.day,
                    claudeTokens: day.claudeTokens,
                    claudeCost: day.claudeCost,
                    codexTokens: day.codexTokens,
                    codexCost: day.codexCost,
                    mix: day.mix
                )
            },
            { day in day.mix == nil ? nil : day.withoutDetail },
        ]
        var days = history.days
        for trim in trims where !fits(days) {
            // Trimming more of the oldest days only ever shrinks the payload,
            // so the fewest that fit is found by bisection, not one encode a day.
            func trimmingOldest(_ count: Int) -> [SyncedDailyUsageDay] {
                days.enumerated().map { $0.offset < count ? (trim($0.element) ?? $0.element) : $0.element }
            }
            guard fits(trimmingOldest(days.count)) else {
                days = trimmingOldest(days.count)
                continue
            }
            var low = 0
            var high = days.count
            while low < high {
                let middle = (low + high) / 2
                if fits(trimmingOldest(middle)) { high = middle } else { low = middle + 1 }
            }
            days = trimmingOldest(low)
        }
        return rebuilt(days)
    }

    /// The daily history as `makeSnapshot` offers it, before budget trimming.
    /// `SyncContentFingerprint` hashes the same value, so a change only in
    /// detail that crosses the wire still republishes.
    static func redactedHistory(
        _ history: DailyUsageHistory,
        throughput: ModelThroughputSnapshot,
        now: Date
    ) -> SyncedDailyUsageHistory {
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.locale = Locale(identifier: "en_US_POSIX")
        sourceCalendar.timeZone = .current
        let sourceToday = sourceCalendar.startOfDay(for: now)
        let firstModelDay = sourceCalendar.date(
            byAdding: .day,
            value: -(modelDetailDays - 1),
            to: sourceToday
        ) ?? sourceToday

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        // Wire day keys are canonical UTC. The receiver validates against the
        // same UTC calendar, so a local/UTC midnight crossing cannot make an
        // otherwise live snapshot invalid before its authenticated expiry.
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        let earliest = calendar.date(
            byAdding: .day,
            value: -SyncedDailyUsageHistory.maximumDays,
            to: start
        ) ?? .distantPast
        let latest = calendar.date(byAdding: .day, value: 1, to: start) ?? now

        var byDay: [String: SyncedDailyUsageDay] = [:]
        for item in history.days where item.date >= earliest && item.date <= latest {
            let components = calendar.dateComponents([.year, .month, .day], from: item.date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else { continue }
            let key = String(format: "%04d-%02d-%02d", year, month, day)
            let detail = UsageDetailRedactor.detail(
                for: item,
                includesModels: item.date >= firstModelDay,
                throughput: throughput
            )
            byDay[key] = SyncedDailyUsageDay(
                day: key,
                claudeTokens: boundedTokens(item.claudeTokens),
                claudeCost: boundedCost(item.claudeCost),
                codexTokens: boundedTokens(item.codexTokens),
                codexCost: boundedCost(item.codexCost),
                agents: detail.agents,
                mix: detail.mix
            )
        }

        return SyncedDailyUsageHistory(
            days: Array(
                byDay.values.sorted { $0.day < $1.day }
                    .suffix(SyncedDailyUsageHistory.maximumDays)
            ),
            capturedAt: history.capturedAt,
            sourceDay: wireDayKey(for: sourceToday, calendar: calendar)
        )
    }

    private static func wireDayKey(for date: Date, calendar: Calendar) -> String? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func boundedTokens(_ value: Int64) -> Int64 {
        min(max(value, 0), SyncedDailyUsageHistory.maximumTokensPerProviderPerDay)
    }

    private static func boundedCost(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), SyncedDailyUsageHistory.maximumCostPerProviderPerDay)
    }

    private static func redact(_ quota: ProviderQuota) -> SyncedProviderQuota {
        let windows = [quota.primary, quota.secondary]
            .compactMap { $0 }
            .enumerated()
            .map { index, window in
                let balance = window.remainingBalance ?? (index == 0 ? quota.remainingBalance : nil)
                return SyncedQuotaWindow(
                    usedPercent: min(max(window.usedPercent, 0), 100),
                    windowMinutes: max(0, window.windowMinutes),
                    resetsAt: window.resetsAt,
                    remainingBalance: balance.map {
                        SyncedQuotaBalance(amount: $0.amount, currencyCode: $0.currencyCode)
                    },
                    // A pool label that fails wire sanitization is dropped, not
                    // rejected: the window's numbers are still correct without it.
                    poolName: SyncedQuotaWindow.sanitizedPoolName(window.poolName)
                )
            }
        let scopedWindows = quota.uniqueScopedWindows.compactMap { scoped -> SyncedScopedQuotaWindow? in
            // Cached PTY output from an older parser can contain a partial
            // repaint where the model label absorbs progress-bar/reset lines.
            // The mobile wire label is deliberately stricter than arbitrary
            // desktop UI text. Drop only that damaged scoped row so one bad
            // optional model limit cannot reject every provider in the snapshot.
            guard let scopeID = wireScopeID(for: scoped), isWireSafe(scoped) else { return nil }
            return SyncedScopedQuotaWindow(
                scopeID: scopeID,
                displayName: scoped.displayName,
                window: SyncedQuotaWindow(
                    usedPercent: min(max(scoped.window.usedPercent, 0), 100),
                    windowMinutes: max(0, scoped.window.windowMinutes),
                    resetsAt: scoped.window.resetsAt,
                    remainingBalance: scoped.window.remainingBalance.map {
                        SyncedQuotaBalance(amount: $0.amount, currencyCode: $0.currencyCode)
                    },
                    poolName: SyncedQuotaWindow.sanitizedPoolName(scoped.window.poolName)
                )
            )
        }
        // Transport validation enforces windows.count + scopedWindows.count <=
        // maximumWindowsPerProvider and rejects the whole snapshot on overflow.
        // A provider with several model pools (Codex now emits a session+weekly
        // pair per pool) can legitimately exceed that, so truncate the scoped
        // tail deterministically — the list is already in the service's semantic
        // order, so the rows that survive are stable across refreshes. Better to
        // drop trailing optional model rows than to let one busy provider get
        // every provider's snapshot rejected.
        let scopedCapacity = max(0, maximumSyncedWindowsPerProvider - windows.count)
        let cappedScopedWindows = Array(scopedWindows.prefix(scopedCapacity))
        return SyncedProviderQuota(
            providerID: stableID(for: quota.provider),
            windows: windows,
            capturedAt: quota.capturedAt,
            statusCode: .available,
            planName: SyncedProviderQuota.sanitizedPlanName(quota.planName),
            scopedWindows: cappedScopedWindows.isEmpty ? nil : cappedScopedWindows
        )
    }

    /// The transport-validation window budget shared by `windows` and
    /// `scopedWindows`. Read from the default configuration so the redactor can
    /// never disagree with what `validatedForTransport` will enforce.
    static var maximumSyncedWindowsPerProvider: Int {
        SyncValidationConfiguration.current().maximumWindowsPerProvider
    }

    static func isWireSafe(_ scoped: ScopedQuotaWindow) -> Bool {
        guard wireScopeID(for: scoped) != nil else { return false }
        return SyncedProviderQuota.sanitizedPlanName(scoped.displayName) == scoped.displayName
    }

    static func wireScopeID(for scoped: ScopedQuotaWindow) -> String? {
        let normalized = scoped.scopeID.lowercased()
        let scopeBytes = normalized.utf8
        guard (1...32).contains(scopeBytes.count),
              scopeBytes.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122) ||
                      (byte >= 48 && byte <= 57) ||
                      byte == 45 || byte == 95
              }) else {
            return nil
        }
        return normalized
    }

    /// Stable, presentation-independent identifiers. Never derive these from
    /// rawValue/displayName, because those are UI and cache compatibility data.
    static func stableID(for provider: ProviderQuota.Provider) -> String {
        switch provider {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        case .grok: "grok"
        // Desktop-only until published consumers support this provider.
        case .grokBot: "grok-bot"
        case .zai: "zai"
        case .zaiTeam: "zaiteam"
        case .copilot: "copilot"
        case .devin: "devin"
        case .windsurf: "windsurf"
        case .openrouter: "openrouter"
        case .antigravity: "antigravity"
        case .opencode: "opencode"
        case .deepseek: "deepseek"
        case .kimi: "kimi"
        case .minimax: "minimax"
        case .mimo: "mimo"
        // Desktop-only until published consumers support this provider.
        case .alibabaTokenPlan: "alibaba-token-plan"
        case .qoder: "qoder"
        case .kiro: "kiro"
        case .volcengine: "volcengine"
        case .ollama: "ollama"
        // Desktop-only: not in SyncedProviderID.supportedOnCurrentMobile.
        case .muse: "muse"
        case .museCode: "muse-code"
        case .amp: "amp"
        case .factory: "factory"
        case .augment: "augment"
        case .thirdParty: "thirdparty"
        }
    }
}
