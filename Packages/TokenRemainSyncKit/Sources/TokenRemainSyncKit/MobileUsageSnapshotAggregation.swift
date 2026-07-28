import Foundation

/// Deterministic iPhone-side projection of independently authenticated Mac
/// snapshots. Quota percentages describe account limits and therefore select
/// the freshest provider observation; opt-in daily usage is machine-local and
/// is summed once per source.
public enum MobileUsageSnapshotAggregator {
    public static let aggregateSourceInstanceID = UUID(
        uuidString: "a66e6b5a-bef4-4f7c-9bb5-3c6dfa52e001"
    )!

    public static func aggregate(
        _ snapshots: [MobileUsageSnapshot],
        now: Date = Date()
    ) throws -> MobileUsageSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        guard snapshots.count <= SyncReplayRegistry.maximumSourceCount else {
            throw MobileUsageAggregationError.tooManySources
        }

        let configuration = SyncValidationConfiguration.current(now: now)
        let validated = try snapshots.map {
            try $0.validatedForConsumption(configuration: configuration)
                .normalizedForWire()
        }.sorted { $0.sourceInstanceID.uuidString < $1.sourceInstanceID.uuidString }

        guard Set(validated.map(\.sourceInstanceID)).count == validated.count else {
            throw MobileUsageAggregationError.duplicateSource
        }

        var providers: [String: ProviderCandidate] = [:]
        for snapshot in validated {
            for provider in snapshot.providers {
                let candidate = ProviderCandidate(
                    provider: provider,
                    snapshotGeneratedAt: snapshot.generatedAt,
                    sourceInstanceID: snapshot.sourceInstanceID
                )
                if let existing = providers[provider.providerID] {
                    if candidate.isFresher(than: existing) {
                        providers[provider.providerID] = candidate
                    }
                } else {
                    providers[provider.providerID] = candidate
                }
            }
        }

        let histories = validated.compactMap(\.dailyUsageHistory)
        let mergedHistory = histories.isEmpty ? nil : merge(histories)
        // The aggregate is valid only for the intersection of every source it
        // contains. Using the newest generation/expiry would extend an older
        // Mac's quota past that authenticated source's own hard lifetime.
        let generatedAt = validated.map(\.generatedAt).min()!
        let expiresAt = validated.map(\.expiresAt).min()!
        let result = MobileUsageSnapshot(
            sourceInstanceID: aggregateSourceInstanceID,
            sequence: validated.map(\.sequence).max()!,
            generatedAt: generatedAt,
            expiresAt: expiresAt,
            providers: SyncedProviderID.canonicalMobileOrder.compactMap {
                providers[$0]?.provider
            },
            aggregateUsage: nil,
            dailyUsageHistory: mergedHistory,
            curatedFeed: nil
        )
        return try result.validatedForConsumption(configuration: configuration)
            .normalizedForWire()
    }

    private static func merge(
        _ histories: [SyncedDailyUsageHistory]
    ) -> SyncedDailyUsageHistory {
        var days: [String: DailyAccumulator] = [:]
        for history in histories {
            for day in history.days {
                days[day.day, default: DailyAccumulator()].add(day)
            }
        }
        return SyncedDailyUsageHistory(
            days: days.keys.sorted().suffix(SyncedDailyUsageHistory.maximumDays).map { day in
                days[day]!.value(day: day)
            },
            capturedAt: histories.map(\.capturedAt).max()!
        )
    }
}

public enum MobileUsageAggregationError: Error, Sendable, Equatable {
    case tooManySources
    case duplicateSource
}

private struct ProviderCandidate {
    let provider: SyncedProviderQuota
    let snapshotGeneratedAt: Date
    let sourceInstanceID: UUID

    func isFresher(than other: ProviderCandidate) -> Bool {
        if provider.capturedAt != other.provider.capturedAt {
            return provider.capturedAt > other.provider.capturedAt
        }
        if snapshotGeneratedAt != other.snapshotGeneratedAt {
            return snapshotGeneratedAt > other.snapshotGeneratedAt
        }
        return sourceInstanceID.uuidString < other.sourceInstanceID.uuidString
    }
}

private struct DailyAccumulator {
    var claudeTokens: Int64 = 0
    var claudeCost: Double = 0
    var codexTokens: Int64 = 0
    var codexCost: Double = 0

    mutating func add(_ day: SyncedDailyUsageDay) {
        claudeTokens = boundedAdd(claudeTokens, day.claudeTokens)
        claudeCost = boundedAdd(claudeCost, day.claudeCost)
        codexTokens = boundedAdd(codexTokens, day.codexTokens)
        codexCost = boundedAdd(codexCost, day.codexCost)
    }

    func value(day: String) -> SyncedDailyUsageDay {
        SyncedDailyUsageDay(
            day: day,
            claudeTokens: claudeTokens,
            claudeCost: claudeCost,
            codexTokens: codexTokens,
            codexCost: codexCost
        )
    }

    private func boundedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            return SyncedDailyUsageHistory.maximumTokensPerProviderPerDay
        }
        return min(sum, SyncedDailyUsageHistory.maximumTokensPerProviderPerDay)
    }

    private func boundedAdd(_ lhs: Double, _ rhs: Double) -> Double {
        let sum = lhs + rhs
        guard sum.isFinite else {
            return SyncedDailyUsageHistory.maximumCostPerProviderPerDay
        }
        return min(sum, SyncedDailyUsageHistory.maximumCostPerProviderPerDay)
    }
}
