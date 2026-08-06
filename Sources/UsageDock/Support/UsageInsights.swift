import Foundation
import SwiftUI

/// Pure, view-independent derivations over the data UsageStore already holds.
///
/// Everything here is computed strictly from live Claude / Codex quota snapshots
/// and today's ccusage totals — it never invents history. Surfaces that would
/// need multi-day history (trends, heat maps) are expected to render an honest
/// empty state rather than call into this type for data it cannot provide.
struct UsageInsights {
    /// 各 provider 当前快照,键缺失即无数据。
    let quotasByProvider: [ProviderQuota.Provider: ProviderQuota]
    let daily: DailyUsage?
    let history: DailyUsageHistory?
    let quotaUsageHistory: QuotaUsageHistory

    init(
        claude: ProviderQuota?,
        codex: ProviderQuota?,
        cursor: ProviderQuota? = nil,
        grok: ProviderQuota? = nil,
        zai: ProviderQuota? = nil,
        others: [ProviderQuota] = [],
        daily: DailyUsage?,
        history: DailyUsageHistory? = nil,
        quotaUsageHistory: QuotaUsageHistory = .empty
    ) {
        var map: [ProviderQuota.Provider: ProviderQuota] = [:]
        for quota in [claude, codex, cursor, grok, zai].compactMap({ $0 }) + others {
            map[quota.provider] = quota
        }
        quotasByProvider = map
        self.daily = daily
        self.history = history
        self.quotaUsageHistory = quotaUsageHistory
    }

    var claude: ProviderQuota? { quotasByProvider[.claude] }
    var codex: ProviderQuota? { quotasByProvider[.codex] }
    var cursor: ProviderQuota? { quotasByProvider[.cursor] }
    var grok: ProviderQuota? { quotasByProvider[.grok] }
    var zai: ProviderQuota? { quotasByProvider[.zai] }

    func quota(for provider: ProviderQuota.Provider) -> ProviderQuota? {
        quotasByProvider[provider]
    }

    /// 全部直查 provider 的现有快照,固定顺序。
    var quotas: [ProviderQuota] {
        ProviderQuota.Provider.displayOrder.compactMap { quotasByProvider[$0] }
    }

    // MARK: - Quota windows

    struct Window: Identifiable {
        let id: String
        let provider: ProviderQuota.Provider
        let windowMinutes: Int
        let usedPercent: Double
        let remainingPercent: Double
        let resetsAt: Date?
        let scopeName: String?
    }

    struct PaceAssessment {
        let window: Window
        let pace: UsagePace
    }

    /// Every official window currently known, in provider then primary→secondary order.
    var windows: [Window] {
        var result: [Window] = []
        for quota in quotas {
            result.append(window(quota.primary, provider: quota.provider, slot: "primary"))
            if let secondary = quota.secondary {
                result.append(window(secondary, provider: quota.provider, slot: "secondary"))
            }
            for scoped in quota.uniqueScopedWindows {
                result.append(window(
                    scoped.window,
                    provider: quota.provider,
                    slot: "scope-\(scoped.scopeID)",
                    scopeName: scoped.displayName
                ))
            }
        }
        return result
    }

    /// Scoped model/pool limits remain inspectable in quota detail, but they
    /// never become the app-wide status signal. This keeps optional Fable,
    /// Spark, MiniMax model lanes, and third-party pools from repainting the
    /// global risk state.
    private var riskWindows: [Window] {
        windows.filter { $0.scopeName == nil }
    }

    private func window(
        _ source: QuotaWindow,
        provider: ProviderQuota.Provider,
        slot: String,
        scopeName: String? = nil
    ) -> Window {
        Window(
            id: "\(provider.rawValue)-\(slot)-\(source.windowMinutes)",
            provider: provider,
            windowMinutes: source.windowMinutes,
            usedPercent: min(100, max(0, source.usedPercent)),
            remainingPercent: min(100, max(0, 100 - source.usedPercent)),
            resetsAt: source.resetsAt,
            scopeName: scopeName
        )
    }

    // MARK: - Risk

    /// Lowest remaining percentage across every known window, or `nil` when no
    /// official quota has been read yet.
    var minRemainingPercent: Double? {
        riskWindows.map(\.remainingPercent).min()
    }

    /// The window that defines the current risk (the scarcest one).
    var constrainingWindow: Window? {
        riskWindows.min(by: { $0.remainingPercent < $1.remainingPercent })
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
        riskWindows
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

        let provider = assessment.window.provider.displayName
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
        let unpricedModels: [String]

        var hasCompletePricing: Bool { unpricedModels.isEmpty }
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
                    cost: agent.estimatedCost,
                    unpricedModels: agent.unpricedModels
                )
            }
            .sorted { $0.tokens > $1.tokens }
    }

    /// 按今日本地 token 用量降序的 provider 排名(去重,只含有真实用量且能映射
    /// 到官方 provider 的 agent)。无本地统计时为空,由调用方决定默认值。
    var providersByTokenUsage: [ProviderQuota.Provider] {
        var seen = Set<ProviderQuota.Provider>()
        return providerUsage.compactMap { usage in
            guard usage.tokens > 0,
                  let provider = usage.provider,
                  seen.insert(provider).inserted
            else { return nil }
            return provider
        }
    }

    var totalTokens: Int64? {
        guard let agents = daily?.agents, !agents.isEmpty else { return nil }
        return agents.reduce(0) { $0 + $1.tokens }
    }

    var totalCost: Double? {
        guard let agents = daily?.agents, !agents.isEmpty else { return nil }
        guard agents.allSatisfy({ $0.unpricedModels.isEmpty }) else { return nil }
        return agents.reduce(0) { $0 + $1.estimatedCost }
    }

    var unpricedModels: [String] {
        Array(Set((daily?.agents ?? []).flatMap(\.unpricedModels))).sorted()
    }

    var historyUnpricedModels: [String] {
        Array(Set((history?.days ?? []).flatMap(\.unpricedModels))).sorted()
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

    // MARK: - Spend tiles (Today / Yesterday / Last 30 Days)

    struct SpendTile: Identifiable {
        let id: String
        let labelKey: String
        let cost: Double?
        let tokens: Int64
    }

    /// OpenUsage 式消费瓦片:今日优先取 `daily`(最鲜),昨日与近 30 天取
    /// `history`。ccusage 不会为无活动日期返回行，因此缺失自然日必须
    /// 归一为零；三个固定摘要不能因为新用户或历史不可用而改变布局。
    func spendTiles(now: Date = .now, calendar: Calendar = .current) -> [SpendTile] {
        let today = calendar.startOfDay(for: now)
        let byDate = localUsageByDate(now: now, calendar: calendar)
        let todayUsage = byDate[today] ?? .zero
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            .map(calendar.startOfDay(for:))
        let yesterdayUsage = yesterday.flatMap { byDate[$0] } ?? .zero
        let last30 = (0..<30).reduce(LocalUsageTotal.zero) { partial, offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return partial
            }
            return partial + (byDate[calendar.startOfDay(for: date)] ?? .zero)
        }

        return [
            SpendTile(
                id: "today",
                labelKey: "usage.spend_today",
                cost: todayUsage.cost,
                tokens: todayUsage.tokens
            ),
            SpendTile(
                id: "yesterday",
                labelKey: "usage.spend_yesterday",
                cost: yesterdayUsage.cost,
                tokens: yesterdayUsage.tokens
            ),
            SpendTile(
                id: "last30",
                labelKey: "usage.spend_last30",
                cost: last30.cost,
                tokens: last30.tokens
            )
        ]
    }

    /// 最近 30 个自然日的 token 总量(旧→新),供菜单栏迷你柱状图使用。
    /// ccusage 只返回有记录的日期；固定窗口会把缺失日补为零，让新用户、
    /// 单日历史与完整历史使用相同的密度，且最右侧始终代表今天。
    func dailyTokenTrend(
        now: Date = .now,
        calendar: Calendar = .current,
        days count: Int = 30
    ) -> [Double] {
        let count = max(2, count)
        let today = calendar.startOfDay(for: now)
        let byDate = localUsageByDate(now: now, calendar: calendar)
        return (0..<count).map { offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset - (count - 1),
                to: today
            ) else { return 0 }
            return Double(byDate[calendar.startOfDay(for: date)]?.tokens ?? 0)
        }
    }

    var dailyTokenTrend: [Double] {
        dailyTokenTrend()
    }

    private struct LocalUsageTotal {
        let tokens: Int64
        let cost: Double?

        static let zero = LocalUsageTotal(tokens: 0, cost: 0)

        static func + (lhs: LocalUsageTotal, rhs: LocalUsageTotal) -> LocalUsageTotal {
            LocalUsageTotal(
                tokens: lhs.tokens + rhs.tokens,
                cost: lhs.cost.flatMap { lhsCost in rhs.cost.map { lhsCost + $0 } }
            )
        }
    }

    /// Builds one canonical per-day map. A live `daily` snapshot overrides the
    /// same calendar day from cached history; missing dates are supplied by the
    /// fixed-window callers as zero rather than represented as absent UI.
    private func localUsageByDate(
        now: Date,
        calendar: Calendar
    ) -> [Date: LocalUsageTotal] {
        var result: [Date: LocalUsageTotal] = [:]
        for day in history?.days ?? [] {
            result[calendar.startOfDay(for: day.date)] = LocalUsageTotal(
                tokens: day.totalTokens,
                cost: day.totalCost
            )
        }
        if let daily {
            result[calendar.startOfDay(for: now)] = LocalUsageTotal(
                tokens: daily.agents.reduce(0) { $0 + $1.tokens },
                cost: daily.agents.allSatisfy { $0.unpricedModels.isEmpty }
                    ? daily.agents.reduce(0) { $0 + $1.estimatedCost }
                    : nil
            )
        }
        return result
    }

    // MARK: - Freshness

    /// Most recent capture time across every live source.
    var lastUpdated: Date? {
        (quotas.map(\.capturedAt) + [daily?.capturedAt].compactMap { $0 })
            .max()
    }

    // MARK: - Helpers

    static func displayName(for agentID: String) -> String {
        provider(for: agentID)?.displayName
            ?? LocalUsageSourceCatalog.displayName(for: agentID)
    }

    static func provider(for agentID: String) -> ProviderQuota.Provider? {
        let normalized = agentID.lowercased()
        if normalized == "z.ai" { return .zai }
        return ProviderQuota.Provider.displayOrder.first {
            $0.ccusageAgentID == normalized
        }
    }

    static func color(for agentID: String) -> Color {
        guard let provider = provider(for: agentID) else { return DashboardTheme.secondaryText }
        return DashboardTheme.accent(for: provider)
    }
}
