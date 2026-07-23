import SwiftUI
import TokenRemainKit
import TokenRemainSyncKit

struct OverviewTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layout = OverviewLayoutStore()
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 64

    /// The hero numeral scales with Dynamic Type. The cap is a guard against
    /// pathological scale factors, set above the AX5 value so it never truncates
    /// growth in practice — the card reflows instead.
    private var cappedHeroSize: CGFloat { min(heroSize, 128) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    CyberPageHeader(title: TRL10n.t("tab.overview"))
                    wordmark
                    if model.snapshot.isEmpty {
                        NotConnectedCard()
                    } else {
                        riskHero
                        ForEach(layout.visibleWidgets) { widget in
                            configuredWidget(widget)
                        }
                        ctaRow
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 96)
            }
            .background(TRTheme.ink)
            // Identity layer: the custom CyberPageHeader replaces the system large
            // title (tab bar still labels the tab; nav bar hidden to avoid a duplicate).
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var wordmark: some View {
        // One brand robot per screen: the expressive hero robot below is the single
        // pixel-robot instance on this tab, so the wordmark row carries the mark by
        // name only (see the risk hero for the mood robot).
        TRAdaptiveRow {
            // Cyberpunk experiment: static chromatic-aberration ghosts behind the
            // wordmark (see Cyberpunk.swift — revert by restoring the plain Text).
            ChromaticText("TokenRemain", font: .system(.headline, design: .monospaced))
            Spacer()
            if model.snapshot.isDemo {
                DemoChip(expandsHitTarget: true).neonGlow(TRTheme.indigo, intensity: 0.5)
            }
            OverviewLayoutMenu(layout: layout)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("TokenRemain")
    }

    @ViewBuilder
    private func configuredWidget(_ widget: OverviewLayoutStore.Widget) -> some View {
        switch widget {
        case .claude:
            OverviewProviderWidget(provider: .claude, layout: layout)
                .overviewWidgetContextMenu(widget: widget, layout: layout)
        case .codex:
            OverviewProviderWidget(provider: .codex, layout: layout)
                .overviewWidgetContextMenu(widget: widget, layout: layout)
        case .todayUsage:
            TodayUsageCard(days: model.dailyUsageHistory?.days ?? [])
                .overviewWidgetContextMenu(widget: widget, layout: layout)
        case .reset:
            countdownCard
                .overviewWidgetContextMenu(widget: widget, layout: layout)
        case .curatedFeed:
            CuratedFeedWidget(feed: model.curatedFeed)
                .overviewWidgetContextMenu(widget: widget, layout: layout)
        }
    }

    // MARK: - Risk hero

    private var riskHero: some View {
        let now = Date()
        let entry = model.entry(at: now)
        let risk = model.insights.riskLevel(at: now)
        let lasts = model.insights.willLastUntilReset(at: now)
        return PixelCard {
            TRAdaptiveRow(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(TRL10n.t("overview.risk.caption"))
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                    HStack(spacing: 6) {
                        PixelBadge(
                            risk.badge,
                            accent: TRTheme.riskAccent(risk),
                            filled: TRTheme.riskIsFilled(risk)
                        )
                        .neonGlow(TRTheme.riskAccent(risk), intensity: 0.5)
                        .accessibilityIdentifier("tr.overview.riskBadge")
                        if !risk.glyph.isEmpty {
                            Text(risk.glyph)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(TRTheme.riskAccent(risk))
                        }
                    }
                    Text(TRL10n.t("overview.min_remaining"))
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                        .padding(.top, 4)
                    // Cyberpunk experiment: dot-matrix hero numerals with a violet
                    // neon bloom (text-white hero → violet-tinted glow). Accessibility
                    // is set explicitly so the "tr.overview.hero" / "46%" contract holds.
                    PixelDigitText(model.entry(at: now).heroText, size: cappedHeroSize, color: TRTheme.text)
                        .neonGlow(TRTheme.violet)
                        .accessibilityLabel(model.entry(at: now).heroText)
                        .accessibilityIdentifier("tr.overview.hero")
                    HStack(spacing: 5) {
                        PixelCheck(lasts ? .checked : .warn, accent: lasts ? TRTheme.cyan : TRTheme.violet)
                        Text(model.insights.paceLine(at: now))
                            .font(.footnote)
                            .foregroundStyle(TRTheme.textDim)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    Text(provenanceText)
                        .font(.caption)
                        .foregroundStyle(isMacSnapshotStale ? TRTheme.violet : TRTheme.textDim)
                    TokenRemainFullBodyRobot(
                        claudeRemaining: entry.remainingPercent(for: .claude),
                        codexRemaining: entry.remainingPercent(for: .codex),
                        size: 96
                    )
                        .accessibilityHidden(true)
                }
            }
        }
        // Cyberpunk structure layer: scanlines + a faint neon border in the risk
        // accent (key card). Revert by removing this modifier.
        .cyberCard(border: TRTheme.riskAccent(risk))
        .trGlassCard(enabled: model.glassEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tr.overview.riskHero")
        .accessibilityLabel(heroAccessibilityLabel(risk: risk, now: now))
    }

    private var provenanceText: String {
        switch model.snapshot.origin {
        case .demo:
            return TRL10n.t("origin.demo.status")
        case .none:
            return TRL10n.t("origin.none.status")
        case .macSync:
            if model.snapshot.isMacSyncExpired(at: Date()) {
                return TRL10n.t("origin.macsync.expired")
            }
            return TRL10n.f(
                "origin.macsync.freshness",
                UsageFormatting.freshnessDescription(
                    since: model.snapshot.providers.map(\.capturedAt).min()
                        ?? model.snapshot.generatedAt,
                    now: Date()
                )
            )
        }
    }

    private var isMacSnapshotStale: Bool {
        model.snapshot.isMacSyncStale(at: Date())
    }

    private func heroAccessibilityLabel(risk: RiskLevel, now: Date) -> String {
        var parts = [
            "\(TRL10n.t("overview.risk.caption"))\(risk.headline)",
            "\(TRL10n.t("overview.min_remaining")) \(model.entry(at: now).heroText)",
            model.insights.paceLine(at: now)
        ]
        if model.snapshot.isDemo { parts.append(TRL10n.t("demo.a11y")) }
        return parts.joined(separator: "，")
    }

    /*
    private func providerCard(provider: ProviderQuota.Provider, lead: UsageInsights.Window) -> some View {
        let now = Date()
        let others = model.insights.windows(for: provider).filter { $0.id != lead.id }
        // The whole card is one tap target that jumps to this provider's tightest
        // window in Limits — unifying the hit region with the Overview CTA below.
        return Button {
            model.open(route: .limits, windowID: lead.id)
        } label: {
            PixelCard {
                VStack(alignment: .leading, spacing: 8) {
                    TRAdaptiveRow {
                        ProviderGlyph(provider: provider, size: 18)
                        Text(provider.shortName)
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(TRTheme.text)
                        Spacer()
                        TRValue(UsageFormatting.percent(lead.remainingPercent.rounded()), size: 20, maxSize: 34)
                            .foregroundStyle(TRTheme.text)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TRTheme.textMute)
                    }
                    // Cyberpunk experiment: subtle neon bloom on the hero-surface meters.
                    SegmentBar(remainingPercent: lead.remainingPercent, accent: TRTheme.accent(for: provider))
                        .neonGlow(TRTheme.accent(for: provider), intensity: 0.4)
                    TRAdaptiveRow {
                        Text(UsageFormatting.windowName(minutes: lead.windowMinutes))
                            .font(.caption)
                            .foregroundStyle(TRTheme.textDim)
                        Spacer(minLength: 0)
                        Text(resetFooter(for: lead, now: now))
                            .font(.caption)
                            .foregroundStyle(TRTheme.textDim)
                    }
                    // Claude's second window rides along as a secondary line.
                    ForEach(others) { other in
                        TRAdaptiveRow {
                            Text(UsageFormatting.windowName(minutes: other.windowMinutes))
                                .font(.caption)
                                .foregroundStyle(TRTheme.textMute)
                            Spacer(minLength: 0)
                            Text(UsageFormatting.percent(other.remainingPercent.rounded()))
                                .font(.system(.caption2, design: .monospaced).monospacedDigit())
                                .foregroundStyle(TRTheme.textDim)
                        }
                    }
                }
            }
            .cyberCard()
        }
        .buttonStyle(.plain)
        // The Button is already a single accessibility element with the button
        // trait; override just its label/hint (no `.accessibilityElement` wrapper,
        // which would double-wrap the node and strand a stray small hit region).
        .accessibilityIdentifier("tr.overview.provider.\(provider.rawValue)")
        .accessibilityLabel(
            "\(provider.shortName)，\(UsageFormatting.windowName(minutes: lead.windowMinutes))，"
            + "\(TRL10n.t("overview.min_remaining")) \(UsageFormatting.percent(lead.remainingPercent.rounded()))"
        )
        .accessibilityHint(TRL10n.t("overview.provider.hint"))
    }

    private func resetFooter(for window: UsageInsights.Window, now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return TRL10n.t("limits.reset.unknown") }
        return UsageFormatting.resetDescription(to: resetsAt, now: now)
    }
    */

    // MARK: - Countdown & trend

    private var countdownCard: some View {
        PixelCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TRL10n.t("overview.reset.card"))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textDim)
                if let reset = model.insights.soonestReset {
                    // Ticks only while foregrounded; nothing schedules work in the model.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        // Cyberpunk experiment: dot-matrix countdown in cyan with a
                        // matching neon bloom.
                        PixelDigitText(
                            UsageFormatting.shortCountdown(to: reset, now: context.date),
                            size: 28,
                            color: TRTheme.cyan
                        )
                        .neonGlow(TRTheme.cyan)
                        .accessibilityHidden(true)
                    }
                    Text(UsageFormatting.absoluteReset(reset))
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                } else {
                    Text(TRL10n.t("limits.reset.unknown"))
                        .font(.footnote)
                        .foregroundStyle(TRTheme.textDim)
                }
                if model.liveActivityState == .active {
                    RecordingDot(animated: !reduceMotion)
                }
            }
        }
        .cyberCard()
        .accessibilityIdentifier("tr.overview.reset.card")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(countdownAccessibilityLabel)
    }

    private var countdownAccessibilityLabel: String {
        guard let reset = model.insights.soonestReset else { return TRL10n.t("limits.reset.unknown") }
        return "\(TRL10n.t("overview.reset.card")) \(UsageFormatting.durationUntil(reset, now: Date()))"
    }

    private var ctaRow: some View {
        Button {
            model.openConstrainingWindow()
        } label: {
            HStack {
                Text(TRL10n.t("overview.cta"))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Image(systemName: "chevron.right")
            }
            .foregroundStyle(TRTheme.indigo)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(TRTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(TRTheme.indigoDim, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .trGlassCard(enabled: model.glassEnabled)
        .accessibilityIdentifier("tr.overview.cta")
    }
}

/// The `.none` origin card. It states plainly what a real source would require and
/// shows no percentages at all.
struct NotConnectedCard: View {
    var body: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TokenRemainFullBodyRobot(
                        claudeRemaining: 0,
                        codexRemaining: 0,
                        size: 64,
                        animated: false
                    )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TRL10n.t("origin.none.title"))
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(TRTheme.text)
                        Text(TRL10n.t("risk.summary.unknown"))
                            .font(.caption)
                            .foregroundStyle(TRTheme.textDim)
                    }
                }
                Text(TRL10n.t("origin.none.body"))
                    .font(.footnote)
                    .foregroundStyle(TRTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cyberCard()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tr.overview.emptyState")
        .accessibilityLabel("\(TRL10n.t("origin.none.title"))。\(TRL10n.t("origin.none.body"))")
    }
}

/// The design's pulsing live dot, shown only while a Live Activity is running.
struct RecordingDot: View {
    let animated: Bool
    @State private var bright = false

    var body: some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(TRTheme.violet)
                .frame(width: 5, height: 5)
                .opacity(bright ? 1 : 0.35)
            Text(TRL10n.t("liveactivity.indicator"))
                .font(.system(size: 9, design: .monospaced).weight(.semibold))
                .foregroundStyle(TRTheme.violet)
        }
        .onAppear {
            guard animated else {
                bright = true
                return
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                bright = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel(TRL10n.t("settings.liveactivity.active"))
    }
}

/// Today's real consumption, mirroring the desktop "今日本地统计" information
/// architecture (total cost → provider split → today/yesterday/30-day tiles →
/// mini trend). Every number is read straight from the synced `dailyUsageHistory`
/// — no live ccusage, no invented values — so the card simply omits anything the
/// history doesn't carry. Adapts to Dynamic Type via `TRAdaptiveRow` (no fixed
/// widths, so nothing truncates at accessibility sizes).
private struct TodayUsageCard: View {
    let days: [SyncedDailyUsageDay]

    private var today: SyncedDailyUsageDay? { days.last }
    private var yesterday: SyncedDailyUsageDay? {
        days.count >= 2 ? days[days.count - 2] : nil
    }
    private var recent: [SyncedDailyUsageDay] { Array(days.suffix(30)) }
    private var trendDays: [SyncedDailyUsageDay] { Array(days.suffix(7)) }

    var body: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 12) {
                if let today {
                    headerRow(today)
                    if today.totalTokens > 0 {
                        providerSplit(today)
                    }
                    Divider().overlay(TRTheme.border)
                    summaryRows
                    if trendDays.count >= 2 {
                        trendRow
                    }
                } else {
                    Text(TRL10n.t("overview.trend.empty"))
                        .font(.footnote)
                        .foregroundStyle(TRTheme.textMute)
                }
            }
        }
        .cyberCard()
    }

    // MARK: Primary — today's total cost

    private func headerRow(_ today: SyncedDailyUsageDay) -> some View {
        TRAdaptiveRow {
            Text(TRL10n.t("today.title"))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(TRTheme.text)
            Spacer(minLength: 8)
            TodayCostDisplay(value: today.totalCost)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tr.overview.today.cost")
        .accessibilityLabel(
            TRL10n.f("overview.today.cost.a11y", String(format: "%.2f", today.totalCost))
        )
    }

    // MARK: Provider token split + proportion

    private func providerSplit(_ today: SyncedDailyUsageDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProportionBar(claude: today.claudeTokens, codex: today.codexTokens)
            VStack(alignment: .leading, spacing: 6) {
                providerLine(.claude, tokens: today.claudeTokens, total: today.totalTokens)
                providerLine(.codex, tokens: today.codexTokens, total: today.totalTokens)
            }
        }
    }

    private func providerLine(
        _ provider: ProviderQuota.Provider,
        tokens: Int64,
        total: Int64
    ) -> some View {
        TRAdaptiveRow {
            HStack(spacing: 6) {
                Circle().fill(TRTheme.accent(for: provider)).frame(width: 7, height: 7)
                Text(provider.shortName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(TRTheme.text)
            }
            Spacer(minLength: 8)
            Text("\(UsageFormatting.compactNumber(tokens)) · \(Self.share(tokens, of: total))")
                .font(.system(.caption, design: .monospaced).monospacedDigit())
                .foregroundStyle(TRTheme.textDim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(provider.shortName)，\(UsageFormatting.compactNumber(tokens)) tokens，\(Self.share(tokens, of: total))"
        )
    }

    // MARK: Today / yesterday / 30-day tiles

    private var summaryRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryLine(TRL10n.t("overview.today.today"), day: today)
            summaryLine(TRL10n.t("overview.today.yesterday"), day: yesterday)
            summaryLine(
                TRL10n.f("overview.today.recent", recent.count),
                cost: recent.reduce(0) { $0 + $1.totalCost },
                tokens: recent.reduce(0) { $0 + $1.totalTokens }
            )
        }
    }

    private func summaryLine(_ title: String, day: SyncedDailyUsageDay?) -> some View {
        summaryLine(title, cost: day?.totalCost, tokens: day?.totalTokens)
    }

    private func summaryLine(_ title: String, cost: Double?, tokens: Int64?) -> some View {
        TRAdaptiveRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(TRTheme.textDim)
            Spacer(minLength: 8)
            Text(cost == nil || tokens == nil
                ? "—"
                : "\(Self.money(cost!)) · \(UsageFormatting.compactNumber(tokens!)) tokens")
                .font(.system(.caption, design: .monospaced).monospacedDigit())
                .foregroundStyle(TRTheme.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cost == nil || tokens == nil
            ? title
            : "\(title)，\(Self.money(cost!))，\(UsageFormatting.compactNumber(tokens!)) tokens")
    }

    // MARK: Compact 7-day trend (folded in from the old standalone card)

    private var trendRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text(TRL10n.t("overview.today.trend"))
                .font(.caption)
                .foregroundStyle(TRTheme.textDim)
            Spacer(minLength: 8)
            MiniStackedDailyUsageBars(days: trendDays)
                .frame(maxWidth: 180)
                .frame(height: 28)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(TRL10n.t("overview.today.trend"))，\(TRL10n.f("trends.meta.days", trendDays.count))"
        )
    }

    // MARK: Formatting

    static func money(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "$%.1fK", value / 1_000) }
        if value >= 1_000 { return String(format: "$%.2fK", value / 1_000) }
        return String(format: "$%.2f", value)
    }

    static func share(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return UsageFormatting.percent(0) }
        return UsageFormatting.percent((Double(part) / Double(total) * 100).rounded())
    }
}

/// Currency symbols and compact suffixes stay in legible SF Mono while the
/// primary digits use the same dot-matrix display layer as the Limits screen.
private struct TodayCostDisplay: View {
    let value: Double

    private var digits: String {
        if value >= 10_000 { return String(format: "%.1f", value / 1_000) }
        if value >= 1_000 { return String(format: "%.2f", value / 1_000) }
        return String(format: "%.2f", value)
    }

    private var suffix: String { value >= 1_000 ? "K" : "" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            Text("$")
            CyberValue(digits, size: 22, color: TRTheme.text, glow: TRTheme.cyan)
            if !suffix.isEmpty { Text(suffix) }
        }
        .font(.system(.headline, design: .monospaced).weight(.semibold))
        .foregroundStyle(TRTheme.text)
        .accessibilityHidden(true)
    }
}

/// A single flat proportion bar: Claude's token share anchored at the leading edge,
/// Codex filling the remainder. Muted provider accents, decorative only.
private struct ProportionBar: View {
    let claude: Int64
    let codex: Int64

    var body: some View {
        GeometryReader { geo in
            let total = max(1, Double(claude + codex))
            let spacing: CGFloat = claude > 0 && codex > 0 ? 2 : 0
            let availableWidth = max(0, geo.size.width - spacing)
            let claudeWidth = availableWidth * Double(claude) / total
            let codexWidth = availableWidth * Double(codex) / total
            HStack(spacing: spacing) {
                Rectangle()
                    .fill(TRTheme.claudeAccent)
                    .frame(width: claude > 0 ? max(3, claudeWidth) : 0)
                Rectangle()
                    .fill(TRTheme.codexAccent)
                    .frame(width: codex > 0 ? max(3, codexWidth) : 0)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Compact counterpart of the full Trends chart: one real day per column with
/// Claude anchored at the baseline and Codex stacked above it.
private struct MiniStackedDailyUsageBars: View {
    let days: [SyncedDailyUsageDay]

    private var peak: Double {
        max(days.map { Double($0.totalTokens) }.max() ?? 0, 1)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    let usableHeight = max(0, geometry.size.height - 1)
                    let claudeHeight = usableHeight * CGFloat(Double(day.claudeTokens) / peak)
                    let codexHeight = usableHeight * CGFloat(Double(day.codexTokens) / peak)
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(TRTheme.codexAccent)
                            .frame(height: max(codexHeight, day.codexTokens > 0 ? 1 : 0))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(TRTheme.claudeAccent)
                            .frame(height: max(claudeHeight, day.claudeTokens > 0 ? 1 : 0))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Overview · concept") {
    OverviewTab()
        .environment(AppModel(arguments: ["-tr-demo", "concept"]))
        .preferredColorScheme(.dark)
}

/// Content-level DEMO marker for tabs without their own wordmark row. It lives in
/// scrollable content rather than the nav bar so it scales with Dynamic Type.
struct DemoHeaderRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.snapshot.isDemo {
            HStack {
                Spacer()
                DemoChip(expandsHitTarget: true).neonGlow(TRTheme.indigo, intensity: 0.5)
            }
        }
    }
}
