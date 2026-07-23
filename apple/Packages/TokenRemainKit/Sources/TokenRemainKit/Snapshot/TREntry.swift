import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Everything any widget, complication or Live Activity needs, derived purely from
/// a snapshot + `now`. Keeping this pure lets the timeline providers stay trivial
/// and lets entry composition be unit-tested without WidgetKit.
public struct TREntry: Sendable, Equatable {
    public struct ProviderLine: Sendable, Equatable, Identifiable {
        public let id: String
        public let provider: ProviderQuota.Provider
        public let remainingPercent: Double
        public let windowMinutes: Int
        public let resetsAt: Date?

        public var displayName: String { provider.shortName }

        public init(
            id: String,
            provider: ProviderQuota.Provider,
            remainingPercent: Double,
            windowMinutes: Int,
            resetsAt: Date?
        ) {
            self.id = id
            self.provider = provider
            self.remainingPercent = remainingPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }
    }

    public let date: Date
    public let origin: SnapshotOrigin
    public let generatedAt: Date
    public let isStale: Bool
    public let isExpired: Bool
    public let minRemainingPercent: Double?
    public let risk: RiskLevel
    public let providers: [ProviderLine]
    public let soonestReset: Date?
    public let willLastUntilReset: Bool
    public let paceLine: String
    public let runOutAt: Date?

    public var isDemo: Bool { origin == .demo }
    public var hasNumbers: Bool { minRemainingPercent != nil && origin != .none }

    /// The provider that owns the scarcest window — the one driving the minimum
    /// remaining figure. Used as the provider indicator on dense surfaces.
    public var constrainingProvider: ProviderQuota.Provider? {
        providers.min(by: { $0.remainingPercent < $1.remainingPercent })?.provider
    }

    /// This provider's lead-window remaining fraction, if present. Used by the
    /// double-ring gauges (watch complication + Lock Screen circular).
    public func remainingPercent(for provider: ProviderQuota.Provider) -> Double? {
        providers.first { $0.provider == provider }?.remainingPercent
    }

    public init(snapshot: UsageSnapshot, now: Date) {
        let insights = snapshot.insights
        date = now
        origin = snapshot.origin
        generatedAt = snapshot.generatedAt
        isStale = snapshot.isMacSyncStale(at: now)
        isExpired = snapshot.isMacSyncExpired(at: now)
        if snapshot.origin == .none || isExpired {
            minRemainingPercent = nil
            risk = .unknown
            providers = []
            soonestReset = nil
            willLastUntilReset = true
            paceLine = isExpired
                ? TRL10n.t("origin.macsync.expired")
                : TRL10n.t("origin.none.status")
            runOutAt = nil
            return
        }
        minRemainingPercent = insights.minRemainingPercent
        risk = insights.riskLevel(at: now)
        let allProviderLines = ProviderQuota.Provider.allCases.compactMap { provider -> ProviderLine? in
            guard let lead = insights.leadWindow(for: provider) else { return nil }
            return ProviderLine(
                id: lead.id,
                provider: provider,
                remainingPercent: lead.remainingPercent,
                windowMinutes: lead.windowMinutes,
                resetsAt: lead.resetsAt
            )
        }
        // Widgets and Live Activities are intentionally dense. Keep the first
        // two stable provider slots (Claude/Codex when available) while the
        // in-app Limits page renders the full set.
        providers = Array(allProviderLines.prefix(2))
        soonestReset = insights.soonestReset
        let assessment = insights.paceAssessment(at: now)
        willLastUntilReset = assessment == nil
        runOutAt = assessment?.pace.estimatedRunOutAt
        paceLine = insights.paceLine(at: now)
    }

    /// Formatted hero percentage, or an em dash in `.none`.
    public var heroText: String {
        guard let minRemainingPercent else { return "—" }
        return UsageFormatting.percent(minRemainingPercent.rounded())
    }

    public static func placeholder(now: Date) -> TREntry {
        TREntry(snapshot: SnapshotComposer.demo(scenario: .concept, now: now), now: now)
    }

    public static func empty(now: Date) -> TREntry {
        TREntry(snapshot: .empty(now: now), now: now)
    }
}

#if canImport(WidgetKit)
/// `date` already carries the entry instant, so no extra shim is needed.
extension TREntry: TimelineEntry {}
#endif
