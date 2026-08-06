import SwiftUI

/// Which slice of history the trend chart shows. Raw value == day count.
enum TrendRange: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30

    var id: Int { rawValue }
    var label: String { L10n.format("trends.range_days", rawValue) }

    /// Thin bars; narrower as the range widens so 30 days still breathe.
    var barWidth: CGFloat {
        switch self {
        case .week: return 12
        case .twoWeeks: return 10
        case .month: return 7
        }
    }

    /// Show every Nth x-axis label so 14 / 30-day ranges stay legible.
    var labelStride: Int {
        switch self {
        case .week: return 1
        case .twoWeeks: return 2
        case .month: return 5
        }
    }
}

/// The single active y-axis. Never dual-axis — tokens and cost are separate views.
enum TrendMetric: CaseIterable, Identifiable {
    case tokens
    case cost

    var id: Self { self }
    var label: String { self == .tokens ? "Tokens" : L10n.text("trends.metric_cost") }
}

// MARK: - Card

/// Trends card: range / metric toggles, a provider legend, an ornamental total
/// sparkline, and the stacked daily bar chart.
/// Backed entirely by real ccusage `daily --by-agent` history — the caller only
/// shows this when at least two days exist.
struct UsageTrendCard: View {
    let days: [DailyUsageHistory.Day]
    var capturedAt: Date?
    let preferredAgentIDs: Set<String>?
    var excludedAgentIDs: Set<String> = []

    @State private var range: TrendRange = .twoWeeks
    @State private var metric: TrendMetric = .tokens
    @State private var pinnedDayID: Date?

    private var availableAgentIDs: [String] {
        Self.agentIDs(in: days)
    }

    private var visibleAgentIDs: Set<String> {
        Set(availableAgentIDs.filter { agentID in
            guard !excludedAgentIDs.contains(agentID) else { return false }
            guard let preferredAgentIDs else { return true }
            return preferredAgentIDs.contains(agentID)
                || UsageInsights.provider(for: agentID) == nil
        })
    }

    /// Most recent `range` days (or everything, if less history exists).
    private var shown: [DailyUsageHistory.Day] {
        Array(days.suffix(range.rawValue))
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: L10n.text("trends.daily_title"), subtitle: L10n.text("trends.daily_subtitle")) {
                    TagPill(text: "LIVE", color: DashboardTheme.codex)
                }

                controls

                sparklineRow

                UsageTrendChart(
                    days: shown,
                    metric: metric,
                    visibleAgentIDs: visibleAgentIDs,
                    pinnedDayID: $pinnedDayID
                )
                    .frame(height: 208)

                if let pinnedDay = shown.first(where: { $0.id == pinnedDayID }) {
                    TrendModelBreakdownPanel(
                        breakdown: .make(
                            day: pinnedDay,
                            agentIDs: availableAgentIDs.filter(visibleAgentIDs.contains),
                            metric: metric
                        ),
                        metric: metric,
                        onClose: { pinnedDayID = nil }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: range) { _, _ in pinnedDayID = nil }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                TrendLegend(agentIDs: availableAgentIDs.filter(visibleAgentIDs.contains))
            }
            Spacer(minLength: 8)
            PixelSegmentedControl(
                options: TrendRange.allCases.map { ($0, $0.label) },
                selection: $range
            )
            PixelSegmentedControl(
                options: TrendMetric.allCases.map { ($0, $0.label) },
                selection: $metric
            )
        }
    }

    @ViewBuilder
    private var sparklineRow: some View {
        let totals = shown.map { day in
            UsageTrendChart.selectedTotal(
                day,
                metric: metric,
                visibleAgentIDs: visibleAgentIDs
            )
        }
        if !visibleAgentIDs.isEmpty, totals.count > 1 {
            HStack(spacing: 8) {
                Text(L10n.text("trends.total_sparkline"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DashboardTheme.mutedText)
                // Neutral (non-series) tint: a total is neither Claude nor Codex,
                // so it must not borrow either provider's identity color.
                DottedSparkline(values: totals, accent: DashboardTheme.secondaryText)
                    .frame(height: 20)
            }
        }
    }

    private static func agentIDs(in days: [DailyUsageHistory.Day]) -> [String] {
        let present = Set(days.flatMap(\.agents).map { $0.id.lowercased() })
        let known = ProviderQuota.Provider.displayOrder
            .map(\.ccusageAgentID)
            .filter(present.contains)
        var seen = Set(known)
        let unknown = days.flatMap(\.agents)
            .map { $0.id.lowercased() }
            .filter { seen.insert($0).inserted }
        return known + unknown
    }
}

// MARK: - Chart

/// Stacked daily bar chart: Claude (violet) anchored to the baseline, Codex
/// (cyan) stacked above, one bar per day. A single metric drives the lone
/// y-axis. Recessive gridlines + axis labels use only text tokens; series color
/// is carried by the bars and the legend, never by text.
struct UsageTrendChart: View {
    let days: [DailyUsageHistory.Day]
    let metric: TrendMetric
    let visibleAgentIDs: Set<String>
    @Binding var pinnedDayID: Date?

    @State private var activeIndex: Int?

    private let leftGutter: CGFloat = 50
    private let xAxisHeight: CGFloat = 18
    private let segmentGap: CGFloat = 2
    private let gridlineFractions: [Double] = [0.25, 0.5, 0.75, 1.0]

    private var series: [String] {
        var seen = Set<String>()
        return days.flatMap(\.agents)
            .map { $0.id.lowercased() }
            .filter { visibleAgentIDs.contains($0) && seen.insert($0).inserted }
    }
    private var hasVisibleSeries: Bool { !series.isEmpty }

    private func value(_ day: DailyUsageHistory.Day, agentID: String) -> Double {
        metric == .tokens
            ? Double(day.tokens(forAgentID: agentID))
            : day.cost(forAgentID: agentID)
    }

    private func total(_ day: DailyUsageHistory.Day) -> Double {
        series.reduce(0) { $0 + value(day, agentID: $1) }
    }

    /// Rounded-up axis ceiling so the tallest stack clears the top gridline.
    private var niceMax: Double {
        let peak = days.map(total).max() ?? 0
        return Self.niceCeiling(peak)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let plotW = size.width - leftGutter
            let plotH = size.height - xAxisHeight
            let columnW = plotW / CGFloat(max(days.count, 1))
            let barW = barWidth(columnW: columnW, cap: barCap)

            ZStack(alignment: .topLeading) {
                if hasVisibleSeries {
                    gridlines(plotW: plotW, plotH: plotH)
                }

                baseline(plotW: plotW, plotH: plotH)

                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let centerX = leftGutter + columnW * (CGFloat(index) + 0.5)
                    let segments = series.compactMap { agentID -> TrendBarSegment? in
                        let height = barHeight(value(day, agentID: agentID), plotH: plotH)
                        guard height > 0 else { return nil }
                        return TrendBarSegment(
                            id: agentID,
                            height: height,
                            color: Self.color(forAgentID: agentID)
                        )
                    }
                    let dimmed = pinnedDayID != nil
                        ? pinnedDayID != day.id
                        : activeIndex != nil && activeIndex != index

                    BarColumn(
                        segments: segments,
                        barWidth: barW,
                        gap: segmentGap,
                        dimmed: dimmed
                    )
                    .frame(width: columnW, height: plotH)
                    .position(x: centerX, y: plotH / 2)
                    .accessibilityLabel(accessibilityLabel(for: day))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pinnedDayID = pinnedDayID == day.id ? nil : day.id
                    }

                    xLabel(index: index, day: day, centerX: centerX, y: plotH)

                    if pinnedDayID == day.id {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(DashboardTheme.violet)
                            .frame(width: max(12, barW), height: 2)
                            .position(x: centerX, y: plotH - 1)
                            .allowsHitTesting(false)
                    }
                }

                if hasVisibleSeries,
                   let activeIndex,
                   days.indices.contains(activeIndex) {
                    tooltip(
                        for: days[activeIndex],
                        index: activeIndex,
                        columnW: columnW,
                        plotW: plotW,
                        plotH: plotH,
                        size: size
                    )
                }

                if !hasVisibleSeries {
                    Text(L10n.text("trends.legend_hint"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DashboardTheme.mutedText)
                        .frame(width: plotW, height: plotH)
                        .position(
                            x: leftGutter + plotW / 2,
                            y: plotH / 2
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let idx = Int((location.x - leftGutter) / columnW)
                    activeIndex = days.indices.contains(idx) ? idx : nil
                case .ended:
                    activeIndex = nil
                }
            }
            .animation(.easeOut(duration: 0.12), value: activeIndex)
            .animation(.easeOut(duration: 0.16), value: pinnedDayID)
            .animation(.easeOut(duration: 0.18), value: visibleAgentIDs)
        }
        .focusable()
        .onExitCommand { pinnedDayID = nil }
        .onMoveCommand(perform: movePinnedDay)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            hasVisibleSeries ? L10n.text("trends.chart_accessibility") : L10n.text("trends.chart_accessibility_empty")
        )
    }

    private var barCap: CGFloat {
        // Match the enclosing range's thin-bar width; fall back for odd counts.
        switch days.count {
        case ...7: return 12
        case ...14: return 10
        default: return 7
        }
    }

    private func barWidth(columnW: CGFloat, cap: CGFloat) -> CGFloat {
        // Always leave a >=2pt canvas gap between adjacent bars.
        Swift.max(2, Swift.min(cap, columnW - 2))
    }

    private func barHeight(_ value: Double, plotH: CGFloat) -> CGFloat {
        guard value > 0, niceMax > 0 else { return 0 }
        return plotH * CGFloat(value / niceMax)
    }

    // MARK: Gridlines + y labels

    @ViewBuilder
    private func baseline(plotW: CGFloat, plotH: CGFloat) -> some View {
        Rectangle()
            .fill(DashboardTheme.secondaryText.opacity(0.58))
            .frame(width: plotW, height: 1)
            .position(
                x: leftGutter + plotW / 2,
                y: plotH - 0.5
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func gridlines(plotW: CGFloat, plotH: CGFloat) -> some View {
        ForEach(gridlineFractions, id: \.self) { fraction in
            let y = plotH - plotH * CGFloat(fraction)
            Rectangle()
                .fill(DashboardTheme.border.opacity(0.4))
                .frame(width: plotW, height: 1)
                .position(x: leftGutter + plotW / 2, y: y)
                .accessibilityHidden(true)

            Text(axisLabel(niceMax * fraction))
                .font(DashboardTheme.Typo.mono(9))
                .foregroundStyle(DashboardTheme.mutedText)
                .lineLimit(1)
                .frame(width: leftGutter - 8, alignment: .trailing)
                .position(x: (leftGutter - 8) / 2, y: y)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func xLabel(index: Int, day: DailyUsageHistory.Day, centerX: CGFloat, y: CGFloat) -> some View {
        // Thin from the most recent day so today is always labeled.
        if (days.count - 1 - index) % strideForCount == 0 {
            Text(Self.dayMonthLabel(day.date))
                .font(DashboardTheme.Typo.mono(9))
                .foregroundStyle(DashboardTheme.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .position(x: centerX, y: y + xAxisHeight / 2 + 1)
                .accessibilityHidden(true)
        }
    }

    private var strideForCount: Int {
        switch days.count {
        case ...7: return 1
        case ...14: return 2
        default: return 5
        }
    }

    // MARK: Tooltip

    @ViewBuilder
    private func tooltip(
        for day: DailyUsageHistory.Day,
        index: Int,
        columnW: CGFloat,
        plotW: CGFloat,
        plotH: CGFloat,
        size: CGSize
    ) -> some View {
        let centerX = leftGutter + columnW * (CGFloat(index) + 0.5)
        let tooltipW: CGFloat = 148
        let clampedX = Swift.min(
            Swift.max(centerX, leftGutter + tooltipW / 2),
            size.width - tooltipW / 2
        )
        let nonZeroSeriesCount = series.filter { value(day, agentID: $0) > 0 }.count
        let stackTop = plotH
            - barHeight(total(day), plotH: plotH)
            - CGFloat(max(0, nonZeroSeriesCount - 1)) * segmentGap
        let y = Swift.max(46, stackTop - 44)

        TrendTooltip(
            title: Self.fullDayLabel(day.date),
            rows: series.map {
                TrendTooltipRow(
                    id: $0,
                    name: UsageInsights.displayName(for: $0),
                    value: valueLabel(value(day, agentID: $0)),
                    color: Self.color(forAgentID: $0)
                )
            },
            total: valueLabel(total(day)),
            hint: L10n.text("trends.tooltip_click_hint")
        )
        .frame(width: tooltipW)
        .position(x: clampedX, y: y)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: Formatting

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .tokens:
            return Self.compactAxisTokens(value)
        case .cost:
            return value >= 100
                ? String(format: "$%.0f", value)
                : String(format: "$%.1f", value)
        }
    }

    /// Short axis token label (e.g. `1.2M`, `750M`, `500K`) that fits the narrow
    /// y gutter — tighter than the two-decimal `compactNumber` used for values.
    static func compactAxisTokens(_ value: Double) -> String {
        let magnitudes: [(threshold: Double, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K")
        ]
        for magnitude in magnitudes where value >= magnitude.threshold {
            let scaled = value / magnitude.threshold
            let text = scaled >= 100
                ? String(format: "%.0f", scaled)
                : String(format: "%.1f", scaled)
            return text + magnitude.suffix
        }
        return String(format: "%.0f", value)
    }

    private func valueLabel(_ value: Double) -> String {
        switch metric {
        case .tokens: return UsageFormatting.compactNumber(Int64(value.rounded()))
        case .cost: return String(format: "$%.2f", value)
        }
    }

    private func accessibilityLabel(for day: DailyUsageHistory.Day) -> String {
        var parts = [Self.fullDayLabel(day.date)]
        for agentID in series {
            parts.append(
                "\(UsageInsights.displayName(for: agentID)) \(valueLabel(value(day, agentID: agentID)))"
            )
        }
        if hasVisibleSeries {
            parts.append(L10n.format("trends.total_format", valueLabel(total(day))))
        } else {
            parts.append(L10n.text("trends.no_provider_selected"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Static helpers

    /// Rounds a peak up to a "nice" axis ceiling (1/2/2.5/5/10 × 10ⁿ).
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let fraction = value / base
        let niceFraction: Double
        switch fraction {
        case ...1: niceFraction = 1
        case ...2: niceFraction = 2
        case ...2.5: niceFraction = 2.5
        case ...5: niceFraction = 5
        default: niceFraction = 10
        }
        return niceFraction * base
    }

    static func dayMonthLabel(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    static func fullDayLabel(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return L10n.format("date.month_day", c.month ?? 0, c.day ?? 0)
    }

    static func selectedTotal(
        _ day: DailyUsageHistory.Day,
        metric: TrendMetric,
        visibleAgentIDs: Set<String>
    ) -> Double {
        visibleAgentIDs.reduce(0) { total, agentID in
            switch metric {
            case .tokens:
                return total + Double(day.tokens(forAgentID: agentID))
            case .cost:
                return total + day.cost(forAgentID: agentID)
            }
        }
    }

    static func color(forAgentID id: String) -> Color {
        if let provider = UsageInsights.provider(for: id) {
            return DashboardTheme.accent(for: provider)
        }
        let scalarSum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return DashboardTheme.providerSlots[scalarSum % DashboardTheme.providerSlots.count]
    }

    private func movePinnedDay(_ direction: MoveCommandDirection) {
        guard !days.isEmpty else { return }
        let current = pinnedDayID.flatMap { id in days.firstIndex { $0.id == id } }
            ?? days.count - 1
        switch direction {
        case .left:
            pinnedDayID = days[max(0, current - 1)].id
        case .right:
            pinnedDayID = days[min(days.count - 1, current + 1)].id
        default:
            break
        }
    }
}

// MARK: - Bar column

/// One day's dynamic stacked bar. Only the topmost non-zero segment rounds its
/// top (the data-end); zero values draw nothing.
private struct TrendBarSegment: Identifiable {
    let id: String
    let height: CGFloat
    let color: Color
}

private struct BarColumn: View {
    let segments: [TrendBarSegment]
    let barWidth: CGFloat
    let gap: CGFloat
    let dimmed: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, item in
                segment(rounded: index == segments.count - 1)
                    .fill(item.color.opacity(dimmed ? 0.4 : 1))
                    .frame(width: barWidth, height: item.height)
                    .offset(y: -offset(before: index))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .ignore)
    }

    private func offset(before index: Int) -> CGFloat {
        segments.prefix(index).reduce(0) { $0 + $1.height + gap }
    }

    /// Top-only 2pt rounding for the stack's data-end; square everywhere else so
    /// segments read as anchored blocks.
    private func segment(rounded: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: rounded ? 2 : 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: rounded ? 2 : 0,
            style: .continuous
        )
    }
}

// MARK: - Legend

/// Static series legend for agents discovered in the user's real ccusage
/// history. Series selection belongs on the tracked-app surface, so the trend
/// card no longer exposes a misleading add-app control.
struct TrendLegend: View {
    let agentIDs: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(agentIDs, id: \.self) { agentID in
                item(agentID: agentID)
            }
        }
    }

    private func item(agentID: String) -> some View {
        let name = UsageInsights.displayName(for: agentID)
        let color = UsageTrendChart.color(forAgentID: agentID)
        return HStack(spacing: 5) {
            if let provider = UsageInsights.provider(for: agentID) {
                BrandIcon(provider: provider)
                    .foregroundStyle(color)
                    .frame(width: 11, height: 11)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DashboardTheme.secondaryText)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 6)
        }
        .accessibilityLabel(L10n.format("trends.legend_label", name))
        .accessibilityValue(L10n.text("trends.legend_visible"))
    }
}

// MARK: - Tooltip

private struct TrendTooltipRow: Identifiable {
    let id: String
    let name: String
    let value: String
    let color: Color
}

private struct TrendTooltip: View {
    let title: String
    let rows: [TrendTooltipRow]
    let total: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DashboardTheme.text)
            ForEach(rows) { item in
                row(color: item.color, name: item.name, value: item.value)
            }
            Divider().overlay(DashboardTheme.border)
            HStack {
                Text(L10n.text("trends.total_label"))
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.secondaryText)
                Spacer(minLength: 8)
                Text(total)
                    .numericFont(10, .bold)
                    .foregroundStyle(DashboardTheme.text)
            }
            Text(hint)
                .font(.system(size: 9))
                .foregroundStyle(DashboardTheme.mutedText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(DashboardTheme.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(DashboardTheme.border, lineWidth: 1)
        )
        .shadow(color: DashboardTheme.canvas.opacity(0.55), radius: 8, y: 3)
    }

    private func row(color: Color, name: String, value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(DashboardTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .numericFont(10, .medium)
                .foregroundStyle(DashboardTheme.text)
        }
    }
}

// MARK: - Pixel segmented control

/// Compact pixel-tech segmented toggle. Selected segment fills with the brand
/// violet accent + ink text; unselected stays text-dim on the inset surface.
struct PixelSegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? DashboardTheme.canvas : DashboardTheme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            selected ? DashboardTheme.violet : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(DashboardTheme.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(DashboardTheme.border, lineWidth: 1)
        )
    }
}
