import Foundation

/// Locally accumulated quota snapshots used by the percentage trend table.
///
/// Every provider exposes a `primary` quota window, even when its duration is
/// provider-specific (for example Cursor's billing month versus Antigravity's
/// five-hour pool). Values therefore stay in separate rows and are never added
/// or stacked as if the windows were directly comparable.
///
/// Samples also keep the secondary (weekly) window and, for managed accounts,
/// the account they came from. Subscription advice needs to know how often a
/// weekly cap filled on each paid account; the trend table still reads only
/// system-account samples, exactly as before.
///
/// Managed-account samples live under their own `accountSamples` key. The
/// production and Dev builds share this cache file, and an older build would
/// read anything under `samples` as the system account's series; it ignores
/// an unknown key instead (and drops it on its next save, which loses only
/// advice history, never corrupts the trend table).
struct QuotaUsageHistory: Sendable, Codable, Equatable {
    struct Sample: Sendable, Codable, Identifiable, Equatable {
        let provider: ProviderQuota.Provider
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Date?
        let capturedAt: Date
        /// Optional so pre-routing history caches remain decodable. Trend
        /// queries keep only the latest route for each host application.
        var attribution: QuotaAttribution? = nil
        /// Nil for the provider's system account, which is the only account
        /// earlier builds recorded, so their samples continue the same series.
        var accountID: ProviderAccountID? = nil
        /// The account-wide secondary window (Claude and Codex weekly caps).
        /// Nil when the source reported none or the cache predates it.
        var secondary: WindowReading? = nil
        /// The tier the account was on (`SubscriptionPlanCatalog.planKey`).
        /// A percentage only means something against its own plan's cap, so
        /// subscription advice ignores samples whose key differs from the
        /// current plan, including every sample written before keys existed.
        var planKey: String? = nil

        var id: String {
            guard let accountID else {
                return "\(provider.rawValue)-\(capturedAt.timeIntervalSinceReferenceDate)"
            }
            return "\(provider.rawValue)-\(accountID.rawValue)-\(capturedAt.timeIntervalSinceReferenceDate)"
        }
    }

    struct WindowReading: Sendable, Codable, Equatable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Date?
    }

    /// Fifteen-minute buckets preserve the shape of short quota windows without
    /// allowing the app's minute-level refresh loop to grow the cache unbounded.
    static let bucketDuration: TimeInterval = 15 * 60
    static let retentionDuration: TimeInterval = 45 * 24 * 60 * 60

    /// System-account samples, the series earlier builds wrote and read.
    var samples: [Sample]
    /// Managed-account samples. Optional so caches without the key decode.
    var accountSamples: [Sample]? = nil

    static let empty = QuotaUsageHistory(samples: [])

    /// Providers with system-account samples, which is what the trend table
    /// lists. Managed-account samples are read by account instead.
    var providers: [ProviderQuota.Provider] {
        let present = Set(samples.map(\.provider))
        return ProviderQuota.Provider.displayOrder.filter(present.contains)
    }

    /// The system account's samples, as the trend table has always read them.
    func samples(
        for provider: ProviderQuota.Provider,
        since cutoff: Date? = nil
    ) -> [Sample] {
        samples(for: provider, account: nil, since: cutoff)
    }

    /// One account's samples. Nil or `.system(provider)` selects the system
    /// account.
    func samples(
        for provider: ProviderQuota.Provider,
        account: ProviderAccountID?,
        since cutoff: Date? = nil
    ) -> [Sample] {
        let accountID = Self.storedAccountID(account, provider: provider)
        let series = accountID == nil ? samples : accountSamples ?? []
        let providerSamples = series.filter { $0.provider == provider && $0.accountID == accountID }
        let currentRouteID = providerSamples.max(by: { $0.capturedAt < $1.capturedAt })?
            .attribution?.routeIdentifier
        return providerSamples.filter { sample in
            sample.attribution?.routeIdentifier == currentRouteID
                && cutoff.map { sample.capturedAt >= $0 } != false
        }
    }

    func recording(
        _ quota: ProviderQuota,
        account: ProviderAccountID? = nil,
        planKey: String? = nil
    ) -> QuotaUsageHistory {
        guard quota.primary.usedPercent.isFinite else { return self }

        let sample = Sample(
            provider: quota.provider,
            usedPercent: min(100, max(0, quota.primary.usedPercent)),
            windowMinutes: quota.primary.windowMinutes,
            resetsAt: quota.primary.resetsAt,
            capturedAt: quota.capturedAt,
            attribution: quota.attribution,
            accountID: Self.storedAccountID(account, provider: quota.provider),
            secondary: quota.secondary.flatMap { window in
                guard window.usedPercent.isFinite else { return nil }
                return WindowReading(
                    usedPercent: min(100, max(0, window.usedPercent)),
                    windowMinutes: window.windowMinutes,
                    resetsAt: window.resetsAt
                )
            },
            planKey: planKey
        )
        let retentionCutoff = sample.capturedAt.addingTimeInterval(-Self.retentionDuration)
        let keepsRecent: (Sample) -> Bool = { $0.capturedAt >= retentionCutoff }
        var updated = (sample.accountID == nil ? samples : accountSamples ?? []).filter(keepsRecent)
        let bucket = Self.bucket(for: sample.capturedAt)

        if let index = updated.firstIndex(where: {
            $0.provider == sample.provider
                && $0.accountID == sample.accountID
                && Self.bucket(for: $0.capturedAt) == bucket
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
                if lhs != rhs { return lhs < rhs }
                return ($0.accountID?.rawValue ?? "") < ($1.accountID?.rawValue ?? "")
            }
            return $0.capturedAt < $1.capturedAt
        }
        guard sample.accountID != nil else {
            return QuotaUsageHistory(samples: updated, accountSamples: accountSamples?.filter(keepsRecent))
        }
        return QuotaUsageHistory(samples: samples.filter(keepsRecent), accountSamples: updated)
    }

    /// The system account is stored as nil so its samples stay one series
    /// with those written before accounts were recorded.
    private static func storedAccountID(
        _ account: ProviderAccountID?,
        provider: ProviderQuota.Provider
    ) -> ProviderAccountID? {
        account == .system(provider) ? nil : account
    }

    private static func bucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / bucketDuration))
    }
}
