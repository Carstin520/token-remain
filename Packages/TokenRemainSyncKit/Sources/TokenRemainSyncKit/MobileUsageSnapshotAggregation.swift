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
        let sourceDays = Set(histories.compactMap(\.sourceDay))
        return SyncedDailyUsageHistory(
            days: days.keys.sorted().suffix(SyncedDailyUsageHistory.maximumDays).map { day in
                days[day]!.value(day: day)
            },
            capturedAt: histories.map(\.capturedAt).max()!,
            sourceDay: sourceDays.count == 1 && histories.allSatisfy({ $0.sourceDay != nil })
                ? sourceDays.first
                : nil
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
    /// Nil once any source reports the day without per-agent detail: a sum
    /// over only some Macs would undercount, so the day falls back to the
    /// legacy columns, which every source fills.
    var agents: [String: AgentAccumulator]? = [:]
    var mix: SyncedTokenMix? = .zero

    mutating func add(_ day: SyncedDailyUsageDay) {
        claudeTokens = SyncedDailyUsageHistory.saturatingAdd(claudeTokens, day.claudeTokens)
        claudeCost = boundedCost(claudeCost + day.claudeCost)
        codexTokens = SyncedDailyUsageHistory.saturatingAdd(codexTokens, day.codexTokens)
        codexCost = boundedCost(codexCost + day.codexCost)

        if let dayAgents = day.agents, agents != nil {
            for agent in dayAgents {
                agents![agent.id, default: AgentAccumulator()].add(agent)
            }
        } else {
            agents = nil
        }
        if let dayMix = day.mix, let current = mix {
            mix = current.adding(dayMix)
        } else {
            mix = nil
        }
    }

    func value(day: String) -> SyncedDailyUsageDay {
        SyncedDailyUsageDay(
            day: day,
            claudeTokens: claudeTokens,
            claudeCost: claudeCost,
            codexTokens: codexTokens,
            codexCost: codexCost,
            agents: agents.map { agents in
                agents.keys.sorted().prefix(SyncedDailyUsageDay.maximumAgents).map {
                    agents[$0]!.value(id: $0)
                }
            },
            mix: mix
        )
    }
}

private struct AgentAccumulator {
    var tokens: Int64 = 0
    var cost: Double = 0
    /// Nil once any source's row for this agent arrives without models.
    var models: [String: SyncedModelUsage]? = [:]

    mutating func add(_ agent: SyncedAgentUsage) {
        tokens = SyncedDailyUsageHistory.saturatingAdd(tokens, agent.tokens)
        cost = boundedCost(cost + agent.cost)
        guard let rows = agent.models, models != nil else {
            models = nil
            return
        }
        for row in rows {
            models![row.id] = models![row.id].map { $0.adding(row) } ?? row
        }
    }

    func value(id: String) -> SyncedAgentUsage {
        SyncedAgentUsage(
            id: id,
            tokens: tokens,
            cost: cost,
            // Two Macs can each send a different top seven; the union folds
            // back to the bound the Mac applies.
            models: models.map { SyncedAgentUsage.boundedModels(Array($0.values)) }
        )
    }
}

private func boundedCost(_ sum: Double) -> Double {
    guard sum.isFinite else {
        return SyncedDailyUsageHistory.maximumCostPerProviderPerDay
    }
    return min(sum, SyncedDailyUsageHistory.maximumCostPerProviderPerDay)
}
