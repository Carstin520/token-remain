import Foundation

/// One privacy-minimized timing sample. It contains only a stable provider slug
/// and four timestamps; quota values, credentials, account data, and content are
/// deliberately absent.
public struct SyncLatencyObservation: Codable, Sendable, Equatable {
    public let providerID: String
    public let providerCapturedAt: Date
    public let macUploadedAt: Date
    public let phoneReceivedAt: Date
    public let phoneRenderedAt: Date

    public init?(
        providerID: String,
        providerCapturedAt: Date,
        macUploadedAt: Date,
        phoneReceivedAt: Date,
        phoneRenderedAt: Date
    ) {
        guard SyncedProviderID.isWellFormed(providerID),
              [providerCapturedAt, macUploadedAt, phoneReceivedAt, phoneRenderedAt]
                .allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            return nil
        }
        self.providerID = providerID
        self.providerCapturedAt = providerCapturedAt
        self.macUploadedAt = macUploadedAt
        self.phoneReceivedAt = phoneReceivedAt
        self.phoneRenderedAt = phoneRenderedAt
    }

    public var endToEndSeconds: TimeInterval? {
        guard providerCapturedAt <= macUploadedAt,
              macUploadedAt <= phoneReceivedAt,
              phoneReceivedAt <= phoneRenderedAt else {
            return nil
        }
        return phoneRenderedAt.timeIntervalSince(providerCapturedAt)
    }
}

public struct SyncLatencySummary: Sendable, Equatable {
    public let sampleCount: Int
    public let p50Seconds: TimeInterval
    public let p95Seconds: TimeInterval
    public let maximumSeconds: TimeInterval

    public static func calculate(
        from observations: [SyncLatencyObservation]
    ) -> SyncLatencySummary? {
        let values = observations.compactMap(\.endToEndSeconds).sorted()
        guard !values.isEmpty else { return nil }
        return SyncLatencySummary(
            sampleCount: values.count,
            p50Seconds: percentile(0.50, values: values),
            p95Seconds: percentile(0.95, values: values),
            maximumSeconds: values[values.count - 1]
        )
    }

    /// Nearest-rank percentile: deterministic for small field samples and the
    /// same definition used by the release acceptance report.
    private static func percentile(
        _ percentile: Double,
        values: [TimeInterval]
    ) -> TimeInterval {
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[min(rank - 1, values.count - 1)]
    }
}
