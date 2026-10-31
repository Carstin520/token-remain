import Foundation

/// Which quota windows need attention first. The Overview window table and
/// the sidebar's Limits count read from here, so both agree on what "at
/// risk" means: a general window projected to run out before its official
/// reset at the current average pace — the same rule
/// `UsageInsights.paceAssessment` uses for the headline. The popover keeps
/// the user's own card order and only names the risk in its strip.
extension UsageInsights {
    /// Every general window projected to run out before reset, soonest first.
    func projectedRunOuts(at now: Date = .now) -> [PaceAssessment] {
        generalWindows
            .compactMap { window -> PaceAssessment? in
                guard let pace = pace(for: window, at: now),
                      !pace.willLastUntilReset,
                      pace.estimatedRunOutAt != nil
                else { return nil }
                return PaceAssessment(window: window, pace: pace)
            }
            .sorted {
                ($0.pace.estimatedRunOutAt ?? .distantFuture)
                    < ($1.pace.estimatedRunOutAt ?? .distantFuture)
            }
    }
}

/// One provider's rows in the Overview "Quota Windows" table. A provider
/// appears once; its account windows (Claude 5 hr and 7 d, Cursor's two
/// pools) are rows inside the group.
struct QuotaWindowGroup: Identifiable {
    struct Row: Identifiable {
        let id: String
        let window: QuotaWindow
        /// The window length, plus its pool only when the provider's pools
        /// differ (Cursor's two); a shared source or pool is on the group.
        let label: String
        let remainingPercent: Double
        let remainingText: String
        let accentProvider: ProviderQuota.Provider
        let pace: UsagePace?

        var runsOutBeforeReset: Bool {
            guard let pace else { return false }
            return !pace.willLastUntilReset && pace.estimatedRunOutAt != nil
        }
    }

    let provider: ProviderQuota.Provider
    /// What every row shares — the API account behind the quota (`Claude
    /// Web`) and/or one pool name (`Gemini`) — said once beside the name.
    let qualifier: String?
    /// The tier named on the subscription card (`QuotaWindowTable.planLabels`).
    let planLabel: String?
    /// A provider-level problem (login not detected, expired credential) or
    /// data older than two refresh cycles. Such groups sort last and dim.
    let attention: String?
    let capturedAt: Date
    let rows: [Row]

    var id: ProviderQuota.Provider { provider }

    var earliestRunOut: Date? {
        rows.compactMap { $0.runsOutBeforeReset ? $0.pace?.estimatedRunOutAt : nil }.min()
    }

    var lowestRemaining: Double {
        rows.map(\.remainingPercent).min() ?? 100
    }
}

enum QuotaWindowTable {
    /// Data counts as stale after two missed refresh cycles (at least ten
    /// minutes, the age at which quota cards already turn their freshness
    /// line amber). Manual refresh has no cycle to miss, so only provider
    /// notices count then.
    static func staleThreshold(refreshInterval: TimeInterval?) -> TimeInterval? {
        guard let refreshInterval else { return nil }
        return max(600, refreshInterval * 2)
    }

    static func groups(
        quotas: [ProviderQuota],
        notices: [ProviderQuota.Provider: String],
        plans: [ProviderQuota.Provider: String] = [:],
        refreshInterval: TimeInterval?,
        now: Date = .now
    ) -> [QuotaWindowGroup] {
        let threshold = staleThreshold(refreshInterval: refreshInterval)
        let groups = quotas.map { quota -> QuotaWindowGroup in
            let windows = [quota.primary] + (quota.secondary.map { [$0] } ?? [])
            let pools = windows.map(\.poolName)
            let sharedPool = Set(pools).count == 1 ? pools[0] : nil
            let rows = windows.enumerated().map { index, window in
                row(window, index: index, in: quota, showsPool: sharedPool == nil, now: now)
            }
            let qualifier = [quota.attribution?.displayName, sharedPool].compactMap { $0 }
            return QuotaWindowGroup(
                provider: quota.provider,
                qualifier: qualifier.isEmpty ? nil : qualifier.joined(separator: " · "),
                planLabel: plans[quota.provider],
                attention: attention(
                    for: quota,
                    notice: notices[quota.provider],
                    threshold: threshold,
                    now: now
                ),
                capturedAt: quota.capturedAt,
                rows: sortedRows(rows)
            )
        }
        return sortedGroups(groups)
    }

    /// A fixed order inside each provider: the shorter window first (5 hr
    /// above 7 d), pools of one length in the source's order. Rows never
    /// trade places as their remaining changes; urgency is the warning mark
    /// on the row and the providers' order.
    static func sortedRows(_ rows: [QuotaWindowGroup.Row]) -> [QuotaWindowGroup.Row] {
        rows.enumerated().sorted { lhs, rhs in
            let l = minutes(lhs.element.window), r = minutes(rhs.element.window)
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    /// At-risk providers first (soonest run-out), then the least remaining;
    /// providers that need attention or carry stale data go last, because
    /// their numbers cannot be trusted for the ranking above.
    static func sortedGroups(_ groups: [QuotaWindowGroup]) -> [QuotaWindowGroup] {
        groups.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if (l.attention == nil) != (r.attention == nil) { return l.attention == nil }
            switch (l.earliestRunOut, r.earliestRunOut) {
            case let (a?, b?) where a != b: return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if l.lowestRemaining != r.lowestRemaining {
                return l.lowestRemaining < r.lowestRemaining
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    static func attentionProviders(
        quotas: [ProviderQuota],
        notices: [ProviderQuota.Provider: String],
        refreshInterval: TimeInterval?,
        now: Date = .now
    ) -> [ProviderQuota.Provider] {
        let threshold = staleThreshold(refreshInterval: refreshInterval)
        let withQuota = quotas.compactMap { quota in
            attention(for: quota, notice: notices[quota.provider], threshold: threshold, now: now) == nil
                ? nil : quota.provider
        }
        let noticeOnly = notices.keys.filter { provider in
            !quotas.contains { $0.provider == provider }
        }
        let all = Set(withQuota).union(noticeOnly)
        return ProviderQuota.Provider.displayOrder.filter(all.contains)
    }

    private static func row(
        _ window: QuotaWindow,
        index: Int,
        in quota: ProviderQuota,
        showsPool: Bool,
        now: Date
    ) -> QuotaWindowGroup.Row {
        let remaining = min(100, max(0, 100 - window.usedPercent))
        let balance = window.remainingBalance ?? (index == 0 ? quota.remainingBalance : nil)
        return QuotaWindowGroup.Row(
            id: "\(quota.provider.rawValue)-\(index)-\(window.windowMinutes)",
            window: window,
            label: [showsPool ? window.poolName : nil, UsageFormatting.windowName(minutes: window.windowMinutes)]
                .compactMap { $0 }
                .joined(separator: " · "),
            remainingPercent: remaining,
            remainingText: QuotaWindowRow.remainingValueText(
                remainingPercent: remaining,
                remainingBalance: balance,
                remainingCredits: window.remainingCredits
            ),
            accentProvider: quota.attribution?.provider ?? quota.provider,
            pace: UsagePace(window: window, now: now)
        )
    }

    /// The tier each provider's subscription lines name — the one chosen on
    /// the subscription card, else the one recognized from the source — so
    /// the table's badge changes with the card. Catalog names ("Pro+") only;
    /// unrecognized source labels (`pro_plus`, "Grok Bot plan") stay on the
    /// Limits card. Accounts of one provider on different tiers give none,
    /// because the table shows a single set of rows per provider.
    static func planLabels(from summary: SubscriptionCostSummary) -> [ProviderQuota.Provider: String] {
        let providers = Set(summary.lines.map(\.provider))
        return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
            summary.catalogPlanName(for: provider).map { (provider, $0) }
        })
    }

    private static func attention(
        for quota: ProviderQuota,
        notice: String?,
        threshold: TimeInterval?,
        now: Date
    ) -> String? {
        if let notice, !notice.isEmpty { return notice }
        if let threshold, now.timeIntervalSince(quota.capturedAt) >= threshold {
            return UsageFormatting.freshnessDescription(since: quota.capturedAt, now: now)
        }
        return nil
    }

    private static func minutes(_ window: QuotaWindow) -> Int {
        window.windowMinutes > 0 ? window.windowMinutes : .max
    }
}
