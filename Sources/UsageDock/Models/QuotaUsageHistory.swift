import Foundation

/// Locally accumulated quota snapshots used by the percentage trend table.
///
/// Every provider exposes a `primary` quota window, even when its duration is
/// provider-specific (for example Cursor's billing month versus Antigravity's
/// five-hour pool). Values therefore stay in separate rows and are never added
/// or stacked as if the windows were directly comparable.
struct QuotaUsageHistory: Sendable, Codable, Equatable {
    struct Sample: Sendable, Codable, Identifiable, Equatable {
        let provider: ProviderQuota.Provider
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Date?
        let capturedAt: Date

        var id: String {
            "\(provider.rawValue)-\(capturedAt.timeIntervalSinceReferenceDate)"
        }
    }

    /// Fifteen-minute buckets preserve the shape of short quota windows without
    /// allowing the app's minute-level refresh loop to grow the cache unbounded.
    static let bucketDuration: TimeInterval = 15 * 60
    static let retentionDuration: TimeInterval = 45 * 24 * 60 * 60

    var samples: [Sample]

    static let empty = QuotaUsageHistory(samples: [])

    var providers: [ProviderQuota.Provider] {
        let present = Set(samples.map(\.provider))
        return ProviderQuota.Provider.displayOrder.filter(present.contains)
    }

    func samples(
        for provider: ProviderQuota.Provider,
        since cutoff: Date? = nil
    ) -> [Sample] {
        samples.filter { sample in
            sample.provider == provider
                && cutoff.map { sample.capturedAt >= $0 } != false
        }
    }

    func recording(_ quota: ProviderQuota) -> QuotaUsageHistory {
        guard quota.primary.usedPercent.isFinite else { return self }

        let sample = Sample(
            provider: quota.provider,
            usedPercent: min(100, max(0, quota.primary.usedPercent)),
            windowMinutes: quota.primary.windowMinutes,
            resetsAt: quota.primary.resetsAt,
            capturedAt: quota.capturedAt
        )
        let retentionCutoff = sample.capturedAt.addingTimeInterval(-Self.retentionDuration)
        var updated = samples.filter { $0.capturedAt >= retentionCutoff }
        let bucket = Self.bucket(for: sample.capturedAt)

        if let index = updated.firstIndex(where: {
            $0.provider == sample.provider && Self.bucket(for: $0.capturedAt) == bucket
        }) {
            if sample.capturedAt >= updated[index].capturedAt {
                updated[index] = sample
            }
        } else {
            updated.append(sample)
        }
        updated.sort {
            if $0.capturedAt == $1.capturedAt {
                let lhs = ProviderQuota.Provider.displayOrder.firstIndex(of: $0.provider) ?? Int.max
                let rhs = ProviderQuota.Provider.displayOrder.firstIndex(of: $1.provider) ?? Int.max
                return lhs < rhs
            }
            return $0.capturedAt < $1.capturedAt
        }
        return QuotaUsageHistory(samples: updated)
    }

    private static func bucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / bucketDuration))
    }
}
