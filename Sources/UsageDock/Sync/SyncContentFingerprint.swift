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
        throughput: ModelThroughputSnapshot = .empty,
        now: Date = Date()
    ) -> String {
        struct Window: Codable {
            let usedPercent: Double
            let windowMinutes: Int
            let resetsAt: Date?
            let remainingBalance: QuotaBalance?
            let poolName: String?
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
            // The redacted days the phone receives, plus the day the Mac calls
            // today; the capture time stays out so an unchanged minute is not
            // a change.
            let historyDays: [SyncedDailyUsageDay]
            let historySourceDay: String?
        }
        let values = MobileSnapshotRedactor.publishedProviders.compactMap { provider -> Provider? in
            guard let quota = quotas[provider] else { return nil }
            let windows = [quota.primary, quota.secondary].compactMap { $0 }.enumerated().map { index, window in
                Window(
                    usedPercent: min(max(window.usedPercent, 0), 100),
                    windowMinutes: max(0, window.windowMinutes),
                    resetsAt: window.resetsAt,
                    remainingBalance: window.remainingBalance ?? (index == 0 ? quota.remainingBalance : nil),
                    poolName: SyncedQuotaWindow.sanitizedPoolName(window.poolName)
                )
            }
            let scopedWindows = quota.uniqueScopedWindows.compactMap { scoped -> ScopedWindow? in
                guard MobileSnapshotRedactor.isWireSafe(scoped),
                      let scopeID = MobileSnapshotRedactor.wireScopeID(for: scoped) else {
                    return nil
                }
                return ScopedWindow(
                    scopeID: scopeID,
                    displayName: scoped.displayName,
                    window: Window(
                        usedPercent: min(max(scoped.window.usedPercent, 0), 100),
                        windowMinutes: max(0, scoped.window.windowMinutes),
                        resetsAt: scoped.window.resetsAt,
                        remainingBalance: scoped.window.remainingBalance,
                        poolName: SyncedQuotaWindow.sanitizedPoolName(scoped.window.poolName)
                    )
                )
            }
            // Mirror the redactor's deterministic scoped truncation so a change
            // in a row that never crosses the wire cannot trigger a re-upload.
            let scopedCapacity = max(
                0,
                MobileSnapshotRedactor.maximumSyncedWindowsPerProvider - windows.count
            )
            return Provider(
                id: MobileSnapshotRedactor.stableID(for: provider),
                planName: SyncedProviderQuota.sanitizedPlanName(quota.planName),
                windows: windows,
                scopedWindows: Array(scopedWindows.prefix(scopedCapacity))
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let syncedHistory = includesUsageHistory
            ? history.map { MobileSnapshotRedactor.redactedHistory($0, throughput: throughput, now: now) }
            : nil
        let payload = Payload(
            providers: values,
            historyDays: syncedHistory?.days ?? [],
            historySourceDay: syncedHistory?.sourceDay
        )
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
