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

    static func makeSnapshot(
        from quotas: [ProviderQuota.Provider: ProviderQuota],
        history: DailyUsageHistory? = nil,
        includesUsageHistory: Bool = false,
        sourceInstanceID: UUID,
        sequence: UInt64,
        generatedAt: Date = Date()
    ) -> MobileUsageSnapshot {
        let providers = publishedProviders.compactMap { provider in
            quotas[provider].map(redact)
        }

        return MobileUsageSnapshot(
            sourceInstanceID: sourceInstanceID,
            sequence: sequence,
            generatedAt: generatedAt,
            expiresAt: generatedAt.addingTimeInterval(maximumLifetime),
            providers: providers,
            aggregateUsage: nil,
            dailyUsageHistory: includesUsageHistory
                ? history.map { redact($0, now: generatedAt) }
                : nil,
            curatedFeed: nil
        )
    }

    private static func redact(
        _ history: DailyUsageHistory,
        now: Date
    ) -> SyncedDailyUsageHistory {
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.locale = Locale(identifier: "en_US_POSIX")
        sourceCalendar.timeZone = .current
        let sourceToday = sourceCalendar.startOfDay(for: now)

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
            byDay[key] = SyncedDailyUsageDay(
                day: key,
                claudeTokens: boundedTokens(item.claudeTokens),
                claudeCost: boundedCost(item.claudeCost),
                codexTokens: boundedTokens(item.codexTokens),
                codexCost: boundedCost(item.codexCost)
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
                    }
                )
            )
        }
        return SyncedProviderQuota(
            providerID: stableID(for: quota.provider),
            windows: [quota.primary, quota.secondary]
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
                        }
                    )
                },
            capturedAt: quota.capturedAt,
            statusCode: .available,
            planName: SyncedProviderQuota.sanitizedPlanName(quota.planName),
            scopedWindows: scopedWindows.isEmpty ? nil : scopedWindows
        )
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
        case .qoder: "qoder"
        case .kiro: "kiro"
        case .volcengine: "volcengine"
        case .ollama: "ollama"
        case .thirdParty: "thirdparty"
        }
    }
}
