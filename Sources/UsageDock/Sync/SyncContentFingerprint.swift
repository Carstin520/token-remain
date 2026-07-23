#if TOKENREMAIN_CLOUD_SYNC
import CryptoKit
import Foundation
import TokenRemainSyncKit

/// Hashes only values that alter the companion presentation. Capture times are
/// intentionally excluded so an unchanged one-minute provider check does not
/// upload the full encrypted snapshot again.
enum SyncContentFingerprint {
    static func make(
        quotas: [ProviderQuota.Provider: ProviderQuota],
        history: DailyUsageHistory?,
        includesUsageHistory: Bool,
        feedPosts: [AIFeedPost]
    ) -> String {
        struct Window: Codable {
            let usedPercent: Double
            let windowMinutes: Int
            let resetsAt: Date?
        }
        struct Provider: Codable {
            let id: String
            let planName: String?
            let windows: [Window]
        }
        struct Payload: Codable {
            let providers: [Provider]
            let historyDays: [DailyUsageHistory.Day]
            let curatedPosts: [SyncedCuratedPost]
        }
        let values = MobileSnapshotRedactor.publishedProviders.compactMap { provider -> Provider? in
            guard let quota = quotas[provider] else { return nil }
            return Provider(
                id: MobileSnapshotRedactor.stableID(for: provider),
                planName: SyncedProviderQuota.sanitizedPlanName(quota.planName),
                windows: [quota.primary, quota.secondary].compactMap { $0 }.map {
                    Window(
                        usedPercent: min(max($0.usedPercent, 0), 100),
                        windowMinutes: max(0, $0.windowMinutes),
                        resetsAt: $0.resetsAt
                    )
                }
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = Payload(
            providers: values,
            historyDays: includesUsageHistory ? (history?.days ?? []) : [],
            curatedPosts: MobileSnapshotRedactor.curatedFeed(
                from: feedPosts,
                generatedAt: Date()
            )?.posts ?? []
        )
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
