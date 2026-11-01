import SwiftUI

/// Overview headline figures in one container, four equal cells split by
/// inset dividers, in MetricCard's type scale. The first cell answers the
/// screen's question: which window runs out before its reset, and when.
struct OverviewKPIStrip: View {
    struct Cell {
        let label: String
        let value: String
        var valueColor: Color = DashboardTheme.text
        var source: MetricCard.Source?
        var caption: String?
        var captionColor: Color = DashboardTheme.secondaryText
    }

    static let weights: [CGFloat] = [1, 1, 1, 1]
    private static let dividerInset: CGFloat = 14

    let insights: UsageInsights
    let now: Date
    let tokens: Cell
    let cost: Cell

    var body: some View {
        DashboardCard(padding: 0) {
            WeightedHStack(weights: Self.weights) {
                cellView(leadCell)
                cellView(lowestRemaining)
                cellView(tokens)
                cellView(cost)
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay {
                GeometryReader { proxy in
                    ForEach(
                        Array(Self.dividerPositions(width: proxy.size.width, weights: Self.weights).enumerated()),
                        id: \.offset
                    ) { _, x in
                        Rectangle()
                            .fill(DashboardSurface.border)
                            .frame(width: 1, height: max(0, proxy.size.height - Self.dividerInset * 2))
                            .position(x: x, y: proxy.size.height / 2)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Lead cell

    /// "Runs out first" when a window is projected to run out before reset;
    /// otherwise the existing sustainability verdict.
    private var leadCell: Cell {
        guard let assessment = insights.paceAssessment(at: now),
              let runOutAt = assessment.pace.estimatedRunOutAt
        else {
            let risk = insights.riskLevel(at: now)
            return Cell(
                label: L10n.text("overview.kpi.sustainability"),
                value: risk == .unknown ? "—" : L10n.text("overview.kpi.until_reset"),
                caption: L10n.text("overview.kpi.pace_basis"),
                captionColor: risk == .unknown ? DashboardTheme.secondaryText : DashboardTheme.success
            )
        }
        let window = assessment.window
        var source = "\(window.displayName) · \(UsageFormatting.windowName(minutes: window.windowMinutes))"
        if let reset = window.resetsAt {
            source += " · \(UsageFormatting.resetDescription(to: reset, now: now))"
        }
        return Cell(
            label: L10n.text("overview.kpi.runs_out_first"),
            value: assessment.pace.isExhausted
                ? L10n.text("pace.exhausted")
                : UsageFormatting.durationUntil(runOutAt, now: now),
            valueColor: DashboardTheme.warning,
            source: MetricCard.Source(provider: window.accentProvider, text: source)
        )
    }

    // MARK: - Lowest remaining

    /// Plain ink: being the lowest is not a risk by itself. Whether that
    /// window lasts rides on the same single line as its source, so every
    /// cell keeps the strip's two-line rhythm.
    private var lowestRemaining: Cell {
        guard let window = insights.constrainingWindow else {
            return Cell(label: L10n.text("overview.kpi.min_remaining"), value: "—")
        }
        var source = "\(window.displayName) · \(UsageFormatting.windowName(minutes: window.windowMinutes))"
        if let pace = insights.pace(for: window, at: now) {
            if pace.isExhausted {
                source += " · \(L10n.text("pace.exhausted"))"
            } else if pace.willLastUntilReset {
                source += " · \(L10n.text("pace.lasts_until_reset"))"
            } else if let runOutAt = pace.estimatedRunOutAt {
                source += " · \(L10n.format("pace.projected_in", UsageFormatting.durationUntil(runOutAt, now: now)))"
            }
        }
        return Cell(
            label: L10n.text("overview.kpi.min_remaining"),
            value: UsageFormatting.percent(window.remainingPercent),
            source: MetricCard.Source(provider: window.accentProvider, text: source)
        )
    }

    // MARK: - Parts

    private func cellView(_ cell: Cell) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label(cell.label)
            RollingText(cell.value)
                .numericFont(20, .semibold)
                .foregroundStyle(cell.valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
            if let source = cell.source {
                sourceRow(source).padding(.top, 5)
            }
            if let caption = cell.caption, cell.source == nil {
                Text(caption)
                    .numericFont(11)
                    .foregroundStyle(cell.captionColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(caption)
                    .padding(.top, 5)
            }
        }
        // The panels' 14 pt inset, so cell text starts on their title edge.
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.label)
        .accessibilityValue(
            [cell.value, cell.source?.text, cell.caption]
                .compactMap { $0 }
                .joined(separator: L10n.text("common.list_separator"))
        )
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.secondaryText)
            .lineLimit(1)
    }

    private func sourceRow(_ source: MetricCard.Source) -> some View {
        HStack(alignment: .top, spacing: 5) {
            BrandIcon(provider: source.provider)
                .frame(width: 11, height: 11)
                .padding(.top, 1)
            Text(source.text)
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(source.text)
        }
    }
}

extension OverviewKPIStrip {
    /// X positions of the dividers between cells, drawn as an overlay so the
    /// layout itself stays a pure width split.
    static func dividerPositions(width: CGFloat, weights: [CGFloat]) -> [CGFloat] {
        let sum = weights.reduce(0, +)
        var x: CGFloat = 0
        return weights.dropLast().map { weight in
            x += width * weight / sum
            return x
        }
    }
}
