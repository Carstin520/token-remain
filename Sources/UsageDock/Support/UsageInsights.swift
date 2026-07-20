import Foundation
import SwiftUI

/// Pure, view-independent derivations over the data UsageStore already holds.
///
/// Everything here is computed strictly from live Claude / Codex quota snapshots
/// and today's ccusage totals — it never invents history. Surfaces that would
/// need multi-day history (trends, heat maps) are expected to render an honest
/// empty state rather than call into this type for data it cannot provide.
struct UsageInsights {
    let claude: ProviderQuota?
    let codex: ProviderQuota?
    let daily: DailyUsage?
    let history: DailyUsageHistory?

    init(
        claude: ProviderQuota?,
        codex: ProviderQuota?,
        daily: DailyUsage?,
        history: DailyUsageHistory? = nil
    ) {
        self.claude = claude
        self.codex = codex
        self.daily = daily
        self.history = history
    }

    // MARK: - Quota windows

    struct Window: Identifiable {
        let id: String
        let provider: ProviderQuota.Provider
        let windowMinutes: Int
        let usedPercent: Double
        let remainingPercent: Double
        let resetsAt: Date?
    }

    struct PaceAssessment {
        let window: Window
        let pace: UsagePace
    }

    /// Every official window currently known, in provider then primary→secondary order.
    var windows: [Window] {
        var result: [Window] = []
        for quota in [claude, codex].compactMap({ $0 }) {
            result.append(window(quota.primary, provider: quota.provider, slot: "primary"))
            if let secondary = quota.secondary {
                result.append(window(secondary, provider: quota.provider, slot: "secondary"))
            }
        }
        return result
    }

    private func window(_ source: QuotaWindow, provider: ProviderQuota.Provider, slot: String) -> Window {
        Window(
            id: "\(provider.rawValue)-\(slot)-\(source.windowMinutes)",
            provider: provider,
            windowMinutes: source.windowMinutes,
            usedPercent: min(100, max(0, source.usedPercent)),
            remainingPercent: min(100, max(0, 100 - source.usedPercent)),
            resetsAt: source.resetsAt
        )
    }

    // MARK: - Risk

    /// Lowest remaining percentage across every known window, or `nil` when no
    /// official quota has been read yet.
    var minRemainingPercent: Double? {
        windows.map(\.remainingPercent).min()
    }

    /// The window that defines the current risk (the scarcest one).
    var constrainingWindow: Window? {
        windows.min(by: { $0.remainingPercent < $1.remainingPercent })
    }

    var riskLevel: RiskLevel {
        riskLevel(at: .now)
    }

    func riskLevel(at now: Date) -> RiskLevel {
        RiskLevel(
            minRemainingPercent: minRemainingPercent,
            projectedRunOut: paceAssessment(at: now) != nil
        )
    }

    func pace(for window: Window, at now: Date = .now) -> UsagePace? {
        UsagePace(
            window: QuotaWindow(
                usedPercent: window.usedPercent,
                windowMinutes: window.windowMinutes,
                resetsAt: window.resetsAt
            ),
            now: now
        )
    }

    /// The earliest projected depletion among windows that will not last until
    /// reset at the current average pace.
    func paceAssessment(at now: Date = .now) -> PaceAssessment? {
        windows
            .compactMap { window -> PaceAssessment? in
                guard let pace = pace(for: window, at: now),
                      !pace.willLastUntilReset,
                      pace.estimatedRunOutAt != nil
                else {
                    return nil
                }
                return PaceAssessment(window: window, pace: pace)
            }
            .min {
                ($0.pace.estimatedRunOutAt ?? .distantFuture)
                    < ($1.pace.estimatedRunOutAt ?? .distantFuture)
            }
    }

    func decisionHeadline(at now: Date = .now) -> String {
        if paceAssessment(at: now) != nil {
            return L10n.text("risk.headline.projected_runout")
        }
        return riskLevel(at: now).headline
    }

    func decisionSummary(at now: Date = .now) -> String {
        guard let assessment = paceAssessment(at: now),
              let runOutAt = assessment.pace.estimatedRunOutAt
        else {
            return riskLevel(at: now).summary
        }

        let provider = assessment.window.provider == .claude ? "Claude" : "Codex"
        let window = UsageFormatting.windowName(minutes: assessment.window.windowMinutes)
        let duration = UsageFormatting.durationUntil(runOutAt, now: now)
        return L10n.format("risk.summary.projected_runout", provider, window, duration)
    }

    /// The soonest upcoming reset among all windows that report one.
    var soonestReset: Date? {
        windows.compactMap(\.resetsAt).min()
    }

    // MARK: - Local usage (today, from ccusage)

    struct ProviderUsage: Identifiable {
        let id: String
        let displayName: String
        let provider: ProviderQuota.Provider?
        let tokens: Int64
        let cost: Double
    }

    /// Today's per-agent token / cost split, highest tokens first.
    var providerUsage: [ProviderUsage] {
        (daily?.agents ?? [])
            .map { agent in
                ProviderUsage(
                    id: agent.id,
                    displayName: Self.displayName(for: agent.id),
                    provider: Self.provider(for: agent.id),
                    tokens: agent.tokens,
                    cost: agent.estimatedCost
                )
            }
            .sorted { $0.tokens > $1.tokens }
    }

    var totalTokens: Int64? {
        guard let agents = daily?.agents, !agents.isEmpty else { return nil }
        return agents.reduce(0) { $0 + $1.tokens }
    }

    var totalCost: Double? {
        guard let agents = daily?.agents, !agents.isEmpty else { return nil }
        return agents.reduce(0) { $0 + $1.estimatedCost }
    }

    /// One provider's share of today's total token usage, expressed as 0...100.
    func tokenShare(for usage: ProviderUsage) -> Double {
        guard let totalTokens, totalTokens > 0 else { return 0 }
        return Double(usage.tokens) / Double(totalTokens) * 100
    }

    /// One provider's share of today's estimated API-priced cost, expressed as
    /// 0...100. This is the only unit encoded by the combined donut chart;
    /// token totals remain explicit labels beside each provider.
    func costShare(for usage: ProviderUsage) -> Double {
        guard let totalCost, totalCost > 0 else { return 0 }
        return usage.cost / totalCost * 100
    }

    // MARK: - Freshness

    /// Most recent capture time across every live source.
    var lastUpdated: Date? {
        [claude?.capturedAt, codex?.capturedAt, daily?.capturedAt]
            .compactMap { $0 }
            .max()
    }

    // MARK: - Helpers

    static func displayName(for agentID: String) -> String {
        switch agentID.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return agentID.capitalized
        }
    }

    static func provider(for agentID: String) -> ProviderQuota.Provider? {
        switch agentID.lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        default: return nil
        }
    }

    static func color(for agentID: String) -> Color {
        switch provider(for: agentID) {
        case .claude: return DashboardTheme.claude
        case .codex: return DashboardTheme.codex
        case .none: return DashboardTheme.purple
        }
    }
}
