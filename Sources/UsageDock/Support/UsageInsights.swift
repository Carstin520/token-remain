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

    init(claude: ProviderQuota?, codex: ProviderQuota?, daily: DailyUsage?) {
        self.claude = claude
        self.codex = codex
        self.daily = daily
    }

    // MARK: - Quota windows

    struct Window: Identifiable {
        let id: String
        let provider: ProviderQuota.Provider
        let windowMinutes: Int
        let remainingPercent: Double
        let resetsAt: Date?
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
        RiskLevel(minRemainingPercent: minRemainingPercent)
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
