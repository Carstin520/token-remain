import SwiftUI

/// Overview: what the user's AI subscriptions cost each month. List prices
/// come from `SubscriptionPlanCatalog`; any row can be replaced with what the
/// user actually pays. The card spans the grid and sizes to its rows, so the
/// usual handful of plans shows without an inner scroll view (DB-002).
/// Each counted plan also says whether its tier fits recent use, and the
/// headline sums those suggestions (`SubscriptionAdvisor`).
struct SubscriptionCostCard: View {
    let accounts: [SubscriptionAccountInput]
    let history: QuotaUsageHistory
    /// This Mac's ccusage days, for judging Claude and Codex by token use.
    let tokenHistory: DailyUsageHistory?
    @ObservedObject var costStore: SubscriptionCostStore = .shared
    @ObservedObject private var currencyStore = CurrencyStore.shared
    @State private var addingAccount: SubscriptionAccountInput?
    /// Advice filters the whole quota history per account. The card's body
    /// runs on every Overview rebuild (page switches, minute ticks, unrelated
    /// store updates), so the result is reused while its inputs and the
    /// minute stay the same. Shared, because each page switch builds a new
    /// card and per-view state would start empty every time.
    private static let adviceMemo = AdviceMemo()

    var body: some View {
        let summary = SubscriptionCostSummary.make(
            accounts: accounts,
            overrides: costStore.overrides,
            rates: currencyStore.rates
        )
        let display = currencyStore.display
        let advice = advice(for: summary)

        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(
                    title: L10n.text("subscription.title"),
                    subtitle: L10n.text("subscription.subtitle")
                ) {
                    addMenu(candidates: addCandidates(excluding: summary))
                }

                if summary.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("subscription.empty_title"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DashboardTheme.text)
                        Text(L10n.text("subscription.empty_message"))
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    overview(summary, advice: advice, display: display)
                    Divider().overlay(DashboardSurface.border)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(summary.lines) { line in
                            SubscriptionCostRow(
                                line: line,
                                detectedPlan: accounts.first { $0.accountID == line.accountID }?.catalogPlan,
                                advice: advice[line.accountID],
                                label: label(for: line, in: summary),
                                display: display,
                                existing: costStore.overrides[line.accountID],
                                requiresAmount: !isListedWithoutOverride(line.accountID),
                                onSave: { costStore.setOverride($0, for: line.accountID) }
                            )
                        }
                    }
                }

                Text(L10n.format("subscription.footnote", SubscriptionPlanCatalog.checkedOn)
                    + " " + L10n.text("subscription.advice.footnote"))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Advice for every line the user pays for; excluded rows get none. The
    /// local token log covers all of a provider's accounts at once, so it is
    /// used only when that provider has a single line on the card.
    private func advice(for summary: SubscriptionCostSummary) -> [ProviderAccountID: SubscriptionAdvice] {
        let key = AdviceMemo.Key(
            lines: summary.lines,
            quotaStamps: summary.lines.map { line in
                accounts.first { $0.accountID == line.accountID }?.hostQuota?.capturedAt
            },
            historyCount: history.samples.count,
            historyLast: history.samples.last?.capturedAt,
            accountHistoryCount: history.accountSamples?.count ?? 0,
            accountHistoryLast: history.accountSamples?.last?.capturedAt,
            tokenHistoryStamp: tokenHistory?.capturedAt,
            minute: Int64(floor(Date().timeIntervalSinceReferenceDate / 60))
        )
        let memo = Self.adviceMemo
        if let cached = memo.value, memo.key == key { return cached }
        let result = computeAdvice(for: summary)
        memo.key = key
        memo.value = result
        return result
    }

    private func computeAdvice(for summary: SubscriptionCostSummary) -> [ProviderAccountID: SubscriptionAdvice] {
        var result: [ProviderAccountID: SubscriptionAdvice] = [:]
        for line in summary.lines where !line.isExcluded {
            let isOnlyLine = summary.lines.filter { $0.provider == line.provider }.count == 1
            result[line.accountID] = SubscriptionAdvisor.advise(
                line: line,
                quota: accounts.first { $0.accountID == line.accountID }?.hostQuota,
                samples: history.samples(for: line.provider, account: line.accountID),
                tokenDays: isOnlyLine ? tokenHistory?.days ?? [] : []
            )
        }
        return result
    }

    /// Total, cost share and the suggested changes side by side, so a wide
    /// window uses its width; below roughly 760 points they stack.
    private func overview(
        _ summary: SubscriptionCostSummary,
        advice: [ProviderAccountID: SubscriptionAdvice],
        display: CurrencyDisplay
    ) -> some View {
        let adviceSummary = SubscriptionAdviceSummary(Array(advice.values))
        let changes = summary.lines.compactMap { line -> AdviceItem? in
            guard let item = advice[line.accountID], item.isActionable else { return nil }
            return AdviceItem(line: line, advice: item, label: label(for: line, in: summary))
        }
        let shares = shareParts(summary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                totalsColumn(summary, advice: adviceSummary, display: display)
                    .frame(minWidth: 180, idealWidth: 200, maxWidth: 230, alignment: .leading)
                columnDivider
                shareColumn(shares, display: display)
                    .frame(minWidth: 240, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
                columnDivider
                adviceColumn(adviceSummary, changes: changes, display: display)
                    .frame(minWidth: 250, idealWidth: 270, maxWidth: .infinity, alignment: .leading)
            }
            // Equal-height columns, so the dividers run the full height.
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                totalsColumn(summary, advice: adviceSummary, display: display)
                shareColumn(shares, display: display)
                adviceColumn(adviceSummary, changes: changes, display: display)
            }
        }
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(DashboardSurface.border)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private func totalsColumn(
        _ summary: SubscriptionCostSummary,
        advice: SubscriptionAdviceSummary,
        display: CurrencyDisplay
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                RollingText(display.amount(usd: summary.monthlyUSD))
                    .numericFont(26, .bold)
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(L10n.text("subscription.per_month"))
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            statusText(summary, display: display)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            if case .changes(_, let delta) = advice.state, abs(delta) >= 0.005 {
                Text(L10n.format("subscription.advice.after_changes", display.amount(usd: summary.monthlyUSD + delta)))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private struct SharePart: Identifiable {
        let id: ProviderAccountID
        let provider: ProviderQuota.Provider
        let label: String
        let usd: Double
        let share: Double
    }

    /// Counted, priced lines in card order. Free and excluded plans have no
    /// share of what the user pays.
    private func shareParts(_ summary: SubscriptionCostSummary) -> [SharePart] {
        let total = summary.monthlyUSD
        guard total > 0 else { return [] }
        return summary.lines.compactMap { line in
            guard !line.isExcluded, let usd = line.monthlyUSD, usd > 0 else { return nil }
            return SharePart(
                id: line.accountID,
                provider: line.provider,
                label: label(for: line, in: summary),
                usd: usd,
                share: usd / total
            )
        }
    }

    private func shareColumn(_ parts: [SharePart], display: CurrencyDisplay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("subscription.share_title"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DashboardTheme.secondaryText)
            if parts.isEmpty {
                Text(L10n.text("common.no_data"))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.mutedText)
            } else {
                SubscriptionShareBar(segments: parts.map { ($0.provider, $0.share) })
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .leading)],
                    alignment: .leading,
                    spacing: 5
                ) {
                    ForEach(parts) { part in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(DashboardTheme.accent(for: part.provider))
                                .frame(width: 6, height: 6)
                            Text(part.label)
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardTheme.text)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(display.amount(usd: part.usd)) · \(UsageFormatting.percent((part.share * 100).rounded()))")
                                .numericFont(11)
                                .foregroundStyle(DashboardTheme.secondaryText)
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private struct AdviceItem: Identifiable {
        let line: SubscriptionCostLine
        let advice: SubscriptionAdvice
        let label: String
        var id: ProviderAccountID { line.accountID }
    }

    private func adviceColumn(
        _ summary: SubscriptionAdviceSummary,
        changes: [AdviceItem],
        display: CurrencyDisplay
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            adviceSummaryText(summary, display: display)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(changes) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.advice.kind.isUpgrade ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(item.advice.kind.isUpgrade ? DashboardTheme.warning : DashboardTheme.success)
                    Text(changeText(item))
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(item.advice.monthlyDeltaUSD.map { SubscriptionAdviceText.signed($0, display: display) } ?? "—")
                        .numericFont(11, .medium)
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func adviceSummaryText(_ advice: SubscriptionAdviceSummary, display: CurrencyDisplay) -> Text {
        switch advice.state {
        case .changes(let count, let delta):
            return Text(Image(systemName: "arrow.up.arrow.down.circle.fill")).foregroundStyle(DashboardTheme.warning)
                + Text(" " + L10n.format("subscription.advice.summary_changes", count, SubscriptionAdviceText.signed(delta, display: display)))
                .foregroundStyle(DashboardTheme.text)
        case .allFit:
            return Text(Image(systemName: "checkmark.circle.fill")).foregroundStyle(DashboardTheme.success)
                + Text(" " + L10n.text("subscription.advice.summary_fit")).foregroundStyle(DashboardTheme.text)
        case .insufficientData:
            return Text(Image(systemName: "clock")).foregroundStyle(DashboardTheme.mutedText)
                + Text(" " + L10n.text("subscription.advice.summary_insufficient"))
                .foregroundStyle(DashboardTheme.secondaryText)
        }
    }

    private func changeText(_ item: AdviceItem) -> String {
        switch item.advice.kind {
        case .upgrade(let target?):
            return "\(item.label) → \(target.displayName)"
        case .downgrade(let target):
            return "\(item.label) → \(target.displayName)"
        case .upgrade(nil):
            return L10n.format(
                item.line.catalogPlan == nil ? "subscription.advice.item_upgrade_generic" : "subscription.advice.item_top_tier",
                item.label
            )
        case .cancel:
            return L10n.format("subscription.advice.item_cancel", item.label)
        case .keep, .insufficientData:
            return item.label
        }
    }

    /// Counts first, then what is not in the headline: rows still needing a
    /// price or an exchange rate (warning ink), and this month's extra usage.
    private func statusText(_ summary: SubscriptionCostSummary, display: CurrencyDisplay) -> Text {
        var parts: [Text] = [
            Text(L10n.format("subscription.priced_count", summary.pricedCount))
                .foregroundStyle(DashboardTheme.secondaryText)
        ]
        if summary.missingPriceCount > 0 {
            parts.append(Text(L10n.format("subscription.missing_count", summary.missingPriceCount))
                .foregroundStyle(DashboardTheme.warning))
        }
        if summary.unconvertibleCount > 0 {
            parts.append(Text(L10n.format("subscription.unconvertible_count", summary.unconvertibleCount))
                .foregroundStyle(DashboardTheme.warning))
        }
        if summary.extraUsageUSD > 0 {
            parts.append(Text(L10n.format("subscription.extra_usage", display.amount(usd: summary.extraUsageUSD)))
                .foregroundStyle(DashboardTheme.secondaryText))
        }
        let separator = Text(" · ").foregroundStyle(DashboardTheme.mutedText)
        return parts.dropFirst().reduce(parts[0]) { $0 + separator + $1 }
    }

    /// The system account needs a name only beside another account of the
    /// same provider.
    private func label(for line: SubscriptionCostLine, in summary: SubscriptionCostSummary) -> String {
        let provider = line.provider.displayName
        if !line.isSystem, !line.accountName.isEmpty {
            return "\(provider) · \(line.accountName)"
        }
        let hasSibling = summary.lines.contains { $0.provider == line.provider && $0.id != line.id }
        return hasSibling ? "\(provider) · \(L10n.text("accounts.system"))" : provider
    }

    private func isListedWithoutOverride(_ id: ProviderAccountID) -> Bool {
        guard let account = accounts.first(where: { $0.accountID == id }) else { return false }
        return !SubscriptionCostSummary.make(accounts: [account], overrides: [:], rates: nil).lines.isEmpty
    }

    /// Connected accounts the card does not list yet — balance APIs or a
    /// subscription product the catalog does not cover.
    private func addCandidates(excluding summary: SubscriptionCostSummary) -> [SubscriptionAccountInput] {
        let listed = Set(summary.lines.map(\.accountID))
        return accounts.filter { $0.quota != nil && !listed.contains($0.accountID) }
    }

    @ViewBuilder
    private func addMenu(candidates: [SubscriptionAccountInput]) -> some View {
        if !candidates.isEmpty {
            Menu {
                ForEach(candidates) { account in
                    Button(menuLabel(for: account)) { addingAccount = account }
                }
            } label: {
                Label(L10n.text("subscription.add"), systemImage: "plus")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .popover(item: $addingAccount, arrowEdge: .bottom) { account in
                SubscriptionPriceEditor(
                    title: menuLabel(for: account),
                    provider: account.provider,
                    detectedPlan: account.catalogPlan,
                    existing: nil,
                    display: currencyStore.display,
                    requiresAmount: true,
                    onSave: { costStore.setOverride($0, for: account.accountID) },
                    onClose: { addingAccount = nil }
                )
            }
        }
    }

    private func menuLabel(for account: SubscriptionAccountInput) -> String {
        var label = account.provider.displayName
        if !account.accountName.isEmpty { label += " · \(account.accountName)" }
        if let plan = SubscriptionPlanCatalog.displayName(provider: account.provider, planName: account.quota?.planName),
           !plan.isEmpty {
            label += " (\(plan))"
        }
        return label
    }
}

/// One bar split by each plan's share of the monthly total, in the
/// provider's accent. Tiny shares keep a sliver so they stay visible.
private struct SubscriptionShareBar: View {
    let segments: [(provider: ProviderQuota.Provider, share: Double)]
    private let height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = segments.count > 1 ? 2 : 0
            let available = max(0, geo.size.width - gap * CGFloat(max(0, segments.count - 1)))
            let widths = TokenCompositionBar.widths(for: segments.map(\.share), available: available, minimum: 3)
            HStack(spacing: gap) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle()
                        .fill(DashboardTheme.accent(for: segments[index].provider))
                        .frame(width: widths[index])
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .leading)
            .background(DashboardSurface.track)
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct SubscriptionCostRow: View {
    let line: SubscriptionCostLine
    let detectedPlan: SubscriptionPlan?
    let advice: SubscriptionAdvice?
    let label: String
    let display: CurrencyDisplay
    let existing: SubscriptionPriceOverride?
    let requiresAmount: Bool
    let onSave: (SubscriptionPriceOverride?) -> Void
    @State private var isEditing = false

    var body: some View {
        Button { isEditing = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BrandIcon(provider: line.provider)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DashboardTheme.text)
                            .lineLimit(1)
                        Text(line.planName ?? L10n.text("subscription.plan_unknown"))
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    // The price never wraps or truncates; a long account name
                    // gives way instead.
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(priceText)
                            .numericFont(12, .semibold)
                            .foregroundStyle(line.source == .missing ? DashboardTheme.warning : DashboardTheme.text)
                            .strikethrough(line.isExcluded, color: DashboardTheme.mutedText)
                        if let sourceText {
                            Text(sourceText)
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardTheme.secondaryText)
                        }
                    }
                    .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DashboardTheme.mutedText)
                }
                if let adviceText {
                    adviceText
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(DashboardSurface.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressRippleButtonStyle(cornerRadius: 9, pressedScale: 0.98, rippleOpacity: 0.12))
        .accessibilityLabel(
            [label, line.planName, priceText, sourceText, advice.map { SubscriptionAdviceText.plain($0, line: line, display: display) }]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityHint(L10n.text("subscription.editor.title"))
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            SubscriptionPriceEditor(
                title: [label, line.planName].compactMap { $0 }.joined(separator: " · "),
                provider: line.provider,
                detectedPlan: detectedPlan,
                existing: existing,
                display: display,
                requiresAmount: requiresAmount,
                onSave: onSave,
                onClose: { isEditing = false }
            )
        }
    }

    private var adviceText: Text? {
        guard let advice else { return nil }
        let (symbol, tint): (String, Color) = switch advice.kind {
        case .upgrade: ("arrow.up.circle.fill", DashboardTheme.warning)
        case .downgrade, .cancel: ("arrow.down.circle.fill", DashboardTheme.success)
        case .keep: ("checkmark.circle", DashboardTheme.success)
        case .insufficientData: ("clock", DashboardTheme.mutedText)
        }
        let headline = Text(Image(systemName: symbol)).foregroundStyle(tint)
            + Text(" " + SubscriptionAdviceText.headline(advice, line: line, display: display))
            .foregroundStyle(advice.isActionable ? DashboardTheme.text : DashboardTheme.secondaryText)
        guard let reasons = SubscriptionAdviceText.reasons(advice) else { return headline }
        return headline + Text(" · " + reasons).foregroundStyle(DashboardTheme.mutedText)
    }

    private var priceText: String {
        if let usd = line.monthlyUSD { return display.amount(usd: usd) }
        if let amount = line.amount { return "\(line.currencyCode) \(String(format: "%.2f", amount))" }
        return L10n.text("subscription.set_price")
    }

    private var sourceText: String? {
        if line.isExcluded { return L10n.text("subscription.source.excluded") }
        switch line.source {
        case .listPrice: return L10n.text("subscription.source.list")
        case .custom: return L10n.text("subscription.source.custom")
        case .missing: return nil
        }
    }
}

/// Words a `SubscriptionAdvice` for the row, its accessibility label and the
/// headline.
private enum SubscriptionAdviceText {
    static func headline(_ advice: SubscriptionAdvice, line: SubscriptionCostLine, display: CurrencyDisplay) -> String {
        let delta = advice.monthlyDeltaUSD.map { signed($0, display: display) }
        switch advice.kind {
        case .upgrade(let target?):
            return L10n.format("subscription.advice.upgrade_to", target.displayName, delta ?? "—")
        case .upgrade(nil):
            return L10n.text(line.catalogPlan == nil ? "subscription.advice.upgrade_generic" : "subscription.advice.top_tier")
        case .downgrade(let target):
            return L10n.format("subscription.advice.downgrade_to", target.displayName, delta ?? "—")
        case .cancel:
            return L10n.format("subscription.advice.cancel", delta ?? "—")
        case .keep:
            return L10n.text("subscription.advice.keep")
        case .insufficientData:
            return L10n.text("subscription.advice.insufficient")
        }
    }

    /// At most two reasons, so a row stays within two lines.
    static func reasons(_ advice: SubscriptionAdvice) -> String? {
        let parts = advice.evidence.prefix(2).map { evidence -> String in
            switch evidence {
            case .longWindow(let minutes, let percent, let isProjection):
                return L10n.format(
                    isProjection ? "subscription.reason.projected" : "subscription.reason.used",
                    UsageFormatting.windowName(minutes: minutes),
                    percentText(percent)
                )
            case .longWindowsRanOut(let ranOut, let total, let minutes):
                return L10n.format("subscription.reason.ran_out", ranOut, total, UsageFormatting.windowName(minutes: minutes))
            case .shortLimitHits(let count, let days, let minutes):
                return L10n.format("subscription.reason.short_hits", UsageFormatting.windowName(minutes: minutes), count, days)
            case .peak(let minutes, let percent):
                return L10n.format(
                    "subscription.reason.peak",
                    UsageFormatting.windowName(minutes: minutes),
                    UsageFormatting.percent(percent.rounded())
                )
            case .tokenDemand(let percent, let weeks):
                return L10n.format("subscription.reason.token_demand", weeks, percentText(percent))
            case .tokenWeeksOver(let over, let weeks):
                return L10n.format("subscription.reason.token_weeks_over", over, weeks)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Projections can run far past the cap; past 999% the digits stop helping.
    static func percentText(_ value: Double) -> String {
        value > 999 ? ">999%" : UsageFormatting.percent(value.rounded())
    }

    static func plain(_ advice: SubscriptionAdvice, line: SubscriptionCostLine, display: CurrencyDisplay) -> String {
        [headline(advice, line: line, display: display), reasons(advice)].compactMap { $0 }.joined(separator: ", ")
    }

    /// `+$80.00` / `−$40.00` in the display currency.
    static func signed(_ usd: Double, display: CurrencyDisplay) -> String {
        if abs(usd) < 0.005 { return display.amount(usd: 0) }
        return (usd > 0 ? "+" : "−") + display.amount(usd: abs(usd))
    }
}

/// Enters what one account actually costs per month: pick a catalog tier,
/// type an amount, or both (the amount wins). An empty amount keeps the list
/// price; a row the user added by hand needs a tier or an amount, since
/// nothing else says it is a paid subscription.
private struct SubscriptionPriceEditor: View {
    let title: String
    let provider: ProviderQuota.Provider
    let detectedPlan: SubscriptionPlan?
    let existing: SubscriptionPriceOverride?
    let display: CurrencyDisplay
    let requiresAmount: Bool
    let onSave: (SubscriptionPriceOverride?) -> Void
    let onClose: () -> Void

    @State private var selectedPlanID: String?
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var excludesFromTotal: Bool

    init(
        title: String,
        provider: ProviderQuota.Provider,
        detectedPlan: SubscriptionPlan?,
        existing: SubscriptionPriceOverride?,
        display: CurrencyDisplay,
        requiresAmount: Bool,
        onSave: @escaping (SubscriptionPriceOverride?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.provider = provider
        self.detectedPlan = detectedPlan
        self.existing = existing
        self.display = display
        self.requiresAmount = requiresAmount
        self.onSave = onSave
        self.onClose = onClose
        _selectedPlanID = State(initialValue: existing?.planID.flatMap {
            SubscriptionPlanCatalog.plan(id: $0, provider: provider)?.id
        })
        _amountText = State(initialValue: existing?.monthlyAmount.map { String(format: "%.2f", $0) } ?? "")
        _currencyCode = State(initialValue: existing?.currencyCode ?? display.currency.rawValue)
        _excludesFromTotal = State(initialValue: existing?.excludesFromTotal ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("subscription.editor.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .lineLimit(2)
            }

            if !tiers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("subscription.editor.plan"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.secondaryText)
                    Picker(L10n.text("subscription.editor.plan"), selection: $selectedPlanID) {
                        Text(detectedChoiceLabel).tag(String?.none)
                        Divider()
                        ForEach(tiers) { plan in
                            Text("\(plan.displayName) · \(CurrencyDisplay.usd.amount(usd: plan.monthlyUSD))")
                                .tag(Optional(plan.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text(listPriceText)
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("subscription.editor.amount"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.secondaryText)
                HStack(spacing: 8) {
                    TextField(
                        effectivePlan == nil
                            ? "0.00"
                            : L10n.text("subscription.editor.amount_placeholder"),
                        text: $amountText
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .accessibilityLabel(L10n.text("subscription.editor.amount"))
                    Picker(L10n.text("subscription.editor.currency"), selection: $currencyCode) {
                        ForEach(currencyChoices, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if isAmountInvalid {
                    Text(L10n.text("subscription.editor.invalid"))
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.warning)
                }
            }

            Toggle(L10n.text("subscription.editor.exclude"), isOn: $excludesFromTotal)
                .font(.system(size: 11))

            HStack(spacing: 8) {
                if existing != nil {
                    Button(L10n.text("subscription.editor.clear")) {
                        onSave(nil)
                        onClose()
                    }
                }
                Spacer(minLength: 8)
                Button(L10n.text("action.cancel"), action: onClose)
                Button(L10n.text("action.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 320)
    }

    private var tiers: [SubscriptionPlan] {
        SubscriptionPlanCatalog.plans(for: provider)
    }

    private var selectedPlan: SubscriptionPlan? {
        selectedPlanID.flatMap { SubscriptionPlanCatalog.plan(id: $0, provider: provider) }
    }

    /// The tier whose list price applies when no amount is typed.
    private var effectivePlan: SubscriptionPlan? {
        selectedPlan ?? detectedPlan
    }

    private var detectedChoiceLabel: String {
        guard let detectedPlan else { return L10n.text("subscription.editor.plan_none") }
        return L10n.format("subscription.editor.plan_detected", detectedPlan.displayName)
    }

    private var listPriceText: String {
        guard let effectivePlan else {
            return L10n.text(tiers.isEmpty ? "subscription.editor.no_list_price" : "subscription.editor.choose_plan")
        }
        return L10n.format("subscription.editor.list_price", CurrencyDisplay.usd.amount(usd: effectivePlan.monthlyUSD))
    }

    /// USD and the display currency always have a rate (or need none); a
    /// previously saved currency stays selectable after the display changes.
    private var currencyChoices: [String] {
        var codes = [DisplayCurrency.usd.rawValue]
        for code in [display.currency.rawValue, existing?.currencyCode].compactMap({ $0 })
        where !codes.contains(code) {
            codes.append(code)
        }
        return codes
    }

    private var trimmedAmount: String {
        amountText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts `19.99` and the decimal-comma `19,99`.
    private var parsedAmount: Double? {
        guard !trimmedAmount.isEmpty else { return nil }
        return Double(trimmedAmount.replacingOccurrences(of: ",", with: "."))
    }

    private var isAmountInvalid: Bool {
        guard !trimmedAmount.isEmpty else { return false }
        guard let parsedAmount else { return true }
        return !draft(amount: parsedAmount).isValid
    }

    private var canSave: Bool {
        if isAmountInvalid { return false }
        return !requiresAmount || parsedAmount != nil || selectedPlanID != nil
    }

    private func draft(amount: Double?) -> SubscriptionPriceOverride {
        SubscriptionPriceOverride(
            planID: selectedPlanID,
            monthlyAmount: amount,
            currencyCode: currencyCode,
            excludesFromTotal: excludesFromTotal
        )
    }

    private func save() {
        guard canSave else { return }
        let amount = parsedAmount
        // Nothing custom left: drop the override so the row follows the
        // detected plan again instead of pinning a no-op entry.
        let isEmpty = selectedPlanID == nil && amount == nil && !excludesFromTotal
        onSave(isEmpty ? nil : draft(amount: amount))
        onClose()
    }
}

/// Last advice result and what it was computed from. A plain reference, so
/// storing a result never invalidates a view. Main-thread only (view bodies).
private final class AdviceMemo {
    struct Key: Equatable {
        let lines: [SubscriptionCostLine]
        let quotaStamps: [Date?]
        let historyCount: Int
        let historyLast: Date?
        let accountHistoryCount: Int
        let accountHistoryLast: Date?
        let tokenHistoryStamp: Date?
        let minute: Int64
    }

    var key: Key?
    var value: [ProviderAccountID: SubscriptionAdvice]?
}
