import SwiftUI

/// Overview: every official account window, grouped by provider and ordered
/// by urgency (`QuotaWindowTable`). Each provider is one band — its mark and
/// name centred on the left, then one row per window: its length right
/// beside the bar, what is left, and when it resets. The pace verdict is a
/// warning mark on rows that run out early; the details (pace gap, outcome,
/// exact reset time, provider notice) are in the hover help.
///
/// Bands sit two to a row, filled left to right in urgency order, so a row
/// never stretches across the whole canvas and its figures stay next to its
/// name. One provider gets the full width; narrower than `twoColumnWidth`
/// the bands take one column. (The window's minimum size keeps the table
/// wider than one column needs, so there is no narrower arrangement.) The
/// card is exactly as tall as its providers need. Columns are fixed shares
/// of the width (no measured sizes).
struct QuotaWindowsPanel: View {
    let groups: [QuotaWindowGroup]
    let now: Date

    /// Provider | window, bar, remaining, resets inside one band, in points
    /// at a band's width beside its neighbour; ratios everywhere else.
    private static let bandWeights: [CGFloat] = [140, 50, 110, 52, 78]
    /// Wide enough that one band's reset times do not read as the next
    /// band's label; a hairline runs down its middle.
    private static let bandColumnGap: CGFloat = 44
    static let twoColumnWidth: CGFloat = 780
    static let oneColumnWidth: CGFloat = 420
    private static let rowHeight: CGFloat = 28

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(
                    title: L10n.text("quota.windows_title"),
                    subtitle: L10n.text("quota.windows_subtitle")
                ) {
                    TagPill(text: "LIVE", color: DashboardTheme.codex, background: DashboardTheme.surface2)
                }
                if groups.isEmpty {
                    EmptyStateView(
                        icon: "gauge.with.dots.needle.bottom.0percent",
                        title: L10n.text("quota.loading_official_title"),
                        message: L10n.text("quota.loading_official_message")
                    )
                } else {
                    // Only arrangements that differ are built: `ViewThatFits`
                    // instantiates and measures every child on each build.
                    if groups.count > 1 {
                        ViewThatFits(in: .horizontal) {
                            bandGrid(columns: 2)
                            bandGrid(columns: 1)
                        }
                    } else {
                        bandGrid(columns: 1)
                    }
                }
            }
        }
    }

    // MARK: - Table

    private func bandGrid(columns: Int) -> some View {
        let ideal = columns > 1 ? Self.twoColumnWidth : Self.oneColumnWidth
        let shares = Array(repeating: CGFloat(1), count: columns)
        let rows = stride(from: 0, to: groups.count, by: columns).map {
            Array(groups[$0..<min($0 + columns, groups.count)])
        }
        return VStack(alignment: .leading, spacing: 0) {
            WeightedHStack(weights: shares, idealWidth: ideal, spacing: Self.bandColumnGap) {
                ForEach(0..<columns, id: \.self) { _ in bandHeader }
            }
            .padding(.bottom, 6)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(DashboardSurface.border)
                WeightedHStack(weights: shares, idealWidth: ideal, spacing: Self.bandColumnGap) {
                    ForEach(0..<columns, id: \.self) { index in
                        if index < row.count {
                            band(row[index])
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .overlay {
            // Shares are equal and the gap symmetric, so the gap's middle is
            // the grid's middle; no measuring needed.
            if columns > 1 {
                Rectangle()
                    .fill(DashboardSurface.border)
                    .frame(width: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var bandHeader: some View {
        WeightedHStack(weights: Self.bandWeights, idealWidth: Self.oneColumnWidth) {
            header(L10n.text("trends.quota_provider"))
            header(L10n.text("trends.quota_window"), alignment: .trailing)
                .padding(.trailing, 8)
            header(L10n.text("overview.remaining_quota"))
            Color.clear.frame(height: 1)
            header(L10n.text("quota.windows_resets"), alignment: .trailing)
        }
    }

    /// One provider: its name centred beside its own rows. A band keeps its
    /// natural height at the top of a grid row, so a one-window provider's
    /// row lines up with its neighbour's first row.
    private func band(_ group: QuotaWindowGroup) -> some View {
        let rowShare = Self.bandWeights.dropFirst().reduce(0, +)
        return WeightedHStack(weights: [Self.bandWeights[0], rowShare], idealWidth: Self.oneColumnWidth) {
            providerCell(group)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.rows) { row in
                    WeightedHStack(
                        weights: Array(Self.bandWeights.dropFirst()),
                        idealWidth: Self.oneColumnWidth - Self.bandWeights[0]
                    ) {
                        windowLabel(row, alignment: .trailing)
                            .padding(.trailing, 8)
                        SolidBar(value: row.remainingPercent / 100, accent: barAccent(row))
                            .padding(.trailing, 10)
                            .frame(maxHeight: .infinity)
                        remainingText(row)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        resetText(row)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                    .frame(height: Self.rowHeight)
                    .opacity(group.attention == nil ? 1 : 0.6)
                    .contentShape(Rectangle())
                    .help(detail(row))
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(detail(row))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The band's name column: mark, name and notice mark on one line; the
    /// plan and what the rows share on a second line, in that order for every
    /// provider, so the badges line up on one edge. Too narrow for both, the
    /// source drops below the badge rather than being cut to a letter.
    private func providerCell(_ group: QuotaWindowGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                BrandIcon(provider: group.provider)
                    .frame(width: 16, height: 16)
                Text(group.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let attention = group.attention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.warning)
                        .help(attention)
                        .accessibilityLabel(attention)
                }
            }
            .opacity(group.attention == nil ? 1 : 0.7)
            if group.qualifier != nil || group.planLabel != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { planAndSource(group) }
                    VStack(alignment: .leading, spacing: 3) { planAndSource(group) }
                }
                .padding(.leading, 23)
            }
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func planAndSource(_ group: QuotaWindowGroup) -> some View {
        if let plan = group.planLabel {
            PixelBadge(text: plan)
                .help(plan)
        }
        if let qualifier = group.qualifier {
            Text(qualifier)
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(qualifier)
        }
    }

    // MARK: - Cells

    private func header(_ text: String, alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.secondaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func windowLabel(_ row: QuotaWindowGroup.Row, alignment: Alignment = .leading) -> some View {
        Text(row.label)
            .font(.system(size: 12))
            .foregroundStyle(DashboardTheme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// The bar keeps the provider's own colour (identity); only the figure
    /// and its mark take warning ink when the window runs out early.
    private func barAccent(_ row: QuotaWindowGroup.Row) -> Color {
        DashboardTheme.quotaAccent(for: row.accentProvider, remainingPercent: row.remainingPercent)
    }

    /// One figure per row. A window projected to run out before its reset
    /// carries a warning mark; healthy rows carry nothing extra.
    private func remainingText(_ row: QuotaWindowGroup.Row) -> some View {
        HStack(spacing: 5) {
            if row.runsOutBeforeReset {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
            }
            RollingText(row.remainingText)
                .numericFont(13, .semibold)
        }
        .foregroundStyle(row.runsOutBeforeReset ? DashboardTheme.warning : DashboardTheme.text)
        .lineLimit(1)
        .fixedSize()
    }

    /// Every reset as a countdown, right-aligned in tabular figures: a
    /// clock inside a day (`4:59`), ticking seconds only in the final hour
    /// (`47:12`), and `6 d 23 hr` beyond; the exact time is in the help.
    @ViewBuilder
    private func resetText(_ row: QuotaWindowGroup.Row) -> some View {
        if let reset = row.window.resetsAt {
            Group {
                if UsageFormatting.showsLiveSecondCountdown(to: reset, now: now) {
                    // Each tick re-lays out the whole dashboard page (~70 ms),
                    // so seconds run only in the final hour, as on the Limits
                    // cards. Whole-second ends keep several countdowns on one
                    // beat instead of one pass per countdown.
                    Text(timerInterval: now...Self.wholeSecond(reset), countsDown: true, showsHours: false)
                } else {
                    Text(Self.resetCountdown(reset, now: now))
                }
            }
            .numericFont(11)
            .foregroundStyle(DashboardTheme.secondaryText)
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.mutedText)
        }
    }

    /// A reset less than a day away shows as an `h:mm` clock, advanced by
    /// the Overview's minute timeline; later ones keep the `6 d 23 hr`
    /// countdown, and a reset already passed says so.
    static func showsResetClock(_ date: Date, now: Date) -> Bool {
        let interval = date.timeIntervalSince(now)
        return interval > 0 && interval < 86_400
    }

    static func resetCountdown(_ date: Date, now: Date) -> String {
        guard date > now else { return L10n.text("reset.in_progress") }
        guard showsResetClock(date, now: now) else { return UsageFormatting.durationUntil(date, now: now) }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.up))
    }

    /// Hover help for a row: the pace verdict and outcome, then the exact
    /// reset time — everything the row itself leaves out.
    private func detail(_ row: QuotaWindowGroup.Row) -> String {
        var parts: [String] = []
        if let pace = row.pace {
            parts.append(paceLabel(pace))
            parts.append(outcome(pace))
        }
        if let reset = row.window.resetsAt {
            parts.append(UsageFormatting.resetDescription(to: reset, now: now))
        }
        return parts.joined(separator: " · ")
    }

    private func paceLabel(_ pace: UsagePace) -> String {
        let delta = UsageFormatting.percent(abs(pace.deltaPercent))
        switch pace.status {
        case .onTrack: return L10n.text("pace.on_track")
        case .reserve: return L10n.format("pace.reserve", delta)
        case .deficit: return L10n.format("pace.deficit", delta)
        }
    }

    private func outcome(_ pace: UsagePace) -> String {
        if pace.willLastUntilReset { return L10n.text("pace.lasts_until_reset") }
        if pace.isExhausted { return L10n.text("pace.exhausted") }
        guard let runOutAt = pace.estimatedRunOutAt else { return L10n.text("pace.projected_early") }
        return L10n.format("pace.projected_in", UsageFormatting.durationUntil(runOutAt, now: now))
    }
}

/// One continuous bar per window. The table packs many rows close together,
/// where segmented bars read as a dense grid; a solid fill keeps each row to
/// one shape. Sizes come from the proposal only, so nothing feeds back.
private struct SolidBar: View {
    let value: Double
    let accent: Color
    var height: CGFloat = 6

    @Environment(\.dashboardSurfaces)
    private var surfaces

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, value))
            // Any remainder keeps a visible sliver, so a nearly empty window
            // never reads as fully used.
            let width = fraction > 0 ? max(height, proxy.size.width * fraction) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(surfaces.track)
                Capsule().fill(accent).frame(width: width)
                    .revealSweep()
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
