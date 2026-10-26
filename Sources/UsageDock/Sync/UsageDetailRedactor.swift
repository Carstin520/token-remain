import Foundation
import TokenRemainSyncKit

/// Per-agent and per-model detail for one synced usage day. Like the rest of
/// `MobileSnapshotRedactor`, every field is chosen explicitly: agent slugs,
/// sanitized model names, token counts by kind, estimated cost and measured
/// output speed. Unpriced-model lists, aliases that fail the wire rules and
/// anything per session, project or prompt stay on the Mac.
enum UsageDetailRedactor {
    static func detail(
        for day: DailyUsageHistory.Day,
        includesModels: Bool,
        throughput: ModelThroughputSnapshot
    ) -> (agents: [SyncedAgentUsage]?, mix: SyncedTokenMix?) {
        var byID: [String: SyncedAgentUsage] = [:]
        var mix: SyncedTokenMix?
        for agent in day.agents {
            let id = LocalUsageSourceCatalog.canonicalID(agent.id)
            guard SyncedProviderID.isWellFormed(id) else { continue }
            let rows = models(of: agent, agentID: id, day: day.date, throughput: throughput)
            for row in rows {
                mix = (mix ?? .zero).adding(row.mix)
            }
            let redacted = SyncedAgentUsage(
                id: id,
                tokens: boundedTokens(agent.tokens),
                cost: cents(agent.cost),
                models: includesModels && !rows.isEmpty ? SyncedAgentUsage.boundedModels(rows) : nil
            )
            byID[id] = byID[id].map { merged($0, redacted) } ?? redacted
        }
        guard !byID.isEmpty else { return (nil, mix) }
        let kept = byID.values
            .sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
            .prefix(SyncedDailyUsageDay.maximumAgents)
            .sorted { $0.id < $1.id }
        return (Array(kept), mix)
    }

    /// The identifier a model crosses devices under, or nil to fold it into
    /// `other`. Vertex-style `name@date` becomes `name-date`, the vendor's
    /// own spelling of the same model.
    static func wireModelID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "-")
        guard id != SyncedModelUsage.otherID, SyncedModelUsage.isWellFormedID(id) else { return nil }
        return id
    }

    private static func models(
        of agent: DailyUsageHistory.Agent,
        agentID: String,
        day: Date,
        throughput: ModelThroughputSnapshot
    ) -> [SyncedModelUsage] {
        let dayKey = ModelThroughputParser.dayKey(day)
        return agent.models.map { model in
            let mix = SyncedTokenMix(
                input: boundedTokens(model.inputTokens),
                output: boundedTokens(model.outputTokens),
                cacheWrite: boundedTokens(model.cacheWriteTokens ?? 0),
                cacheRead: boundedTokens(model.cacheReadTokens ?? 0),
                cacheUnsplit: model.cacheWriteTokens == nil || model.cacheReadTokens == nil
                    ? boundedTokens(model.cacheTokens)
                    : 0
            )
            guard model.id != SyncedModelUsage.otherID, let id = wireModelID(model.id) else {
                return SyncedModelUsage(
                    id: SyncedModelUsage.otherID,
                    mix: mix,
                    cost: cents(model.cost),
                    count: min(model.constituentCount, SyncedModelUsage.maximumConstituents)
                )
            }
            let bucket = throughput.buckets[ModelThroughputSnapshot.key(
                day: dayKey,
                agentID: agentID,
                modelID: model.id
            )]
            return SyncedModelUsage(
                id: id,
                mix: mix,
                cost: cents(model.cost),
                speed: bucket.flatMap(speed)
            )
        }
    }

    /// Raw inputs, not a rate: the phone applies the desktop's noise floor
    /// after merging every Mac. Tenths of a second keep the payload small.
    private static func speed(_ bucket: ThroughputBucket) -> SyncedThroughput? {
        guard bucket.samples > 0, bucket.outputTokens > 0,
              bucket.seconds.isFinite, bucket.seconds > 0 else { return nil }
        return SyncedThroughput(
            outputTokens: boundedTokens(bucket.outputTokens),
            seconds: min((bucket.seconds * 10).rounded() / 10, SyncedThroughput.maximumSeconds),
            samples: min(bucket.samples, SyncedThroughput.maximumSamples)
        )
    }

    private static func merged(_ lhs: SyncedAgentUsage, _ rhs: SyncedAgentUsage) -> SyncedAgentUsage {
        let models: [SyncedModelUsage]? = switch (lhs.models, rhs.models) {
        case let (left?, right?): SyncedAgentUsage.boundedModels(left + right)
        default: nil
        }
        return SyncedAgentUsage(
            id: lhs.id,
            tokens: SyncedDailyUsageHistory.saturatingAdd(lhs.tokens, rhs.tokens),
            cost: cents(lhs.cost + rhs.cost),
            models: models
        )
    }

    private static func boundedTokens(_ value: Int64) -> Int64 {
        min(max(value, 0), SyncedDailyUsageHistory.maximumTokensPerProviderPerDay)
    }

    /// Display precision; full doubles would roughly double each row's size.
    private static func cents(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let bounded = min(max(value, 0), SyncedDailyUsageHistory.maximumCostPerProviderPerDay)
        return (bounded * 100).rounded() / 100
    }
}
