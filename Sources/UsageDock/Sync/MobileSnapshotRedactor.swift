#if TOKENREMAIN_CLOUD_SYNC
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
    static let publishedProviders: [ProviderQuota.Provider] = ProviderQuota.Provider.displayOrder

    static func makeSnapshot(
        from quotas: [ProviderQuota.Provider: ProviderQuota],
        history: DailyUsageHistory? = nil,
        includesUsageHistory: Bool = false,
        feedPosts: [AIFeedPost] = [],
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
            curatedFeed: curatedFeed(from: feedPosts, generatedAt: generatedAt)
        )
    }

    static func curatedFeed(
        from posts: [AIFeedPost],
        generatedAt: Date
    ) -> SyncedCuratedFeed? {
        let earliest = generatedAt.addingTimeInterval(-SyncedCuratedFeed.maximumPostAge)
        let values = posts
            .filter { $0.createdAt >= earliest && $0.createdAt <= generatedAt.addingTimeInterval(5 * 60) }
            .compactMap(redact)
            .reduce(into: [SyncedCuratedPost]()) { result, post in
                guard result.count < SyncedCuratedFeed.maximumPosts,
                      !result.contains(where: { $0.id == post.id }) else { return }
                result.append(post)
            }
        guard !values.isEmpty else { return nil }
        return SyncedCuratedFeed(posts: values, capturedAt: generatedAt)
    }

    private static func redact(_ post: AIFeedPost) -> SyncedCuratedPost? {
        guard (1...64).contains(post.id.utf8.count),
              post.id.utf8.allSatisfy({ (48...57).contains($0) }),
              (1...15).contains(post.username.utf8.count),
              post.username.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) ||
                      (byte >= 97 && byte <= 122) ||
                      (byte >= 48 && byte <= 57) ||
                      byte == 95
              }),
              isBoundedPublicText(post.displayName, maximumUTF8Bytes: 160),
              isBoundedPublicText(post.text, maximumUTF8Bytes: 2_000),
              let url = URL(string: "https://x.com/\(post.username)/status/\(post.id)") else {
            return nil
        }
        let priority: SyncedCuratedPost.Priority = switch post.priority {
        case .tokenReset: .tokenReset
        case .majorUpdate: .majorUpdate
        case .normal: .normal
        }
        return SyncedCuratedPost(
            id: post.id,
            username: post.username,
            displayName: post.displayName,
            text: post.text,
            createdAt: post.createdAt,
            url: url,
            priority: priority
        )
    }

    private static func isBoundedPublicText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || scalar.value >= 32
        }
    }

    private static func redact(
        _ history: DailyUsageHistory,
        now: Date
    ) -> SyncedDailyUsageHistory {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
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
            capturedAt: history.capturedAt
        )
    }

    private static func boundedTokens(_ value: Int64) -> Int64 {
        min(max(value, 0), SyncedDailyUsageHistory.maximumTokensPerProviderPerDay)
    }

    private static func boundedCost(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), SyncedDailyUsageHistory.maximumCostPerProviderPerDay)
    }

    private static func redact(_ quota: ProviderQuota) -> SyncedProviderQuota {
        SyncedProviderQuota(
            providerID: stableID(for: quota.provider),
            windows: [quota.primary, quota.secondary]
                .compactMap { $0 }
                .map {
                    SyncedQuotaWindow(
                        usedPercent: min(max($0.usedPercent, 0), 100),
                        windowMinutes: max(0, $0.windowMinutes),
                        resetsAt: $0.resetsAt
                    )
                },
            capturedAt: quota.capturedAt,
            statusCode: .available,
            planName: SyncedProviderQuota.sanitizedPlanName(quota.planName)
        )
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
        case .copilot: "copilot"
        case .devin: "devin"
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
        }
    }
}
#endif
