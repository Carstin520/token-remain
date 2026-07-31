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
        includesUsageHistory: Bool
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
            let scopedWindows: [ScopedWindow]
        }
        struct ScopedWindow: Codable {
            let scopeID: String
            let displayName: String
            let window: Window
        }
        struct Payload: Codable {
            let providers: [Provider]
            let historyDays: [DailyUsageHistory.Day]
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
                },
                scopedWindows: (quota.scopedWindows ?? []).map {
                    ScopedWindow(
                        scopeID: $0.scopeID,
                        displayName: $0.displayName,
                        window: Window(
                            usedPercent: min(max($0.window.usedPercent, 0), 100),
                            windowMinutes: max(0, $0.window.windowMinutes),
                            resetsAt: $0.window.resetsAt
                        )
                    )
                }
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = Payload(
            providers: values,
            historyDays: includesUsageHistory ? (history?.days ?? []) : []
        )
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
