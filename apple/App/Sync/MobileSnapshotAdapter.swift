import Foundation
import TokenRemainKit
import TokenRemainSyncKit

/// iPhone's pure consumption boundary. Decryption and CloudKit fetching stay
/// outside this type; it only turns an already validated sync DTO into the local
/// snapshot used by the app, widgets, Live Activity, and Watch fan-out.
enum MobileSnapshotAdapter {
    static func usageSnapshot(from source: MobileUsageSnapshot) -> UsageSnapshot {
        let providers = source.providers.compactMap { sourceQuota -> ProviderQuota? in
            guard sourceQuota.statusCode == .available else { return nil }

            guard let provider = ProviderQuota.Provider(syncID: sourceQuota.providerID) else {
                // The wire protocol deliberately permits future provider IDs.
                // An older iPhone ignores those values without rejecting the
                // rest of the authenticated Mac snapshot.
                return nil
            }

            let windows = sourceQuota.windows.enumerated()
                .filter {
                    $0.element.usedPercent.isFinite &&
                        (0...100).contains($0.element.usedPercent) &&
                        $0.element.windowMinutes >= 0
                }
                .sorted { lhs, rhs in
                    // `0` means a non-periodic pool, which is broader than an
                    // actual quota window. Retain source ordering for ties.
                    let lhsMinutes = lhs.element.windowMinutes == 0 ? Int.max : lhs.element.windowMinutes
                    let rhsMinutes = rhs.element.windowMinutes == 0 ? Int.max : rhs.element.windowMinutes
                    return lhsMinutes == rhsMinutes ? lhs.offset < rhs.offset : lhsMinutes < rhsMinutes
                }
                .map(\.element)
            guard let primary = windows.first else { return nil }

            return ProviderQuota(
                provider: provider,
                primary: QuotaWindow(
                    usedPercent: primary.usedPercent,
                    windowMinutes: primary.windowMinutes,
                    resetsAt: primary.resetsAt
                ),
                secondary: windows.dropFirst().first.map {
                    QuotaWindow(
                        usedPercent: $0.usedPercent,
                        windowMinutes: $0.windowMinutes,
                        resetsAt: $0.resetsAt
                    )
                },
                planName: sourceQuota.planName,
                capturedAt: sourceQuota.capturedAt
            )
        }

        return UsageSnapshot(
            origin: .macSync,
            generatedAt: source.generatedAt,
            providers: providers,
            dailyTokens: nil
        )
    }
}
