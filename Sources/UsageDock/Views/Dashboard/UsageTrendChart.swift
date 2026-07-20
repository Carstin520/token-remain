import SwiftUI

/// Which slice of history the trend chart shows. Raw value == day count.
enum TrendRange: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30

    var id: Int { rawValue }
    var label: String { "\(rawValue) 天" }

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
    var label: String { self == .tokens ? "Tokens" : "成本" }
}

// MARK: - Card

/// Trends card: range / metric toggles, an independently filterable provider
/// legend, an ornamental total sparkline, and the stacked daily bar chart.
/// Backed entirely by real ccusage `daily --by-agent` history — the caller only
/// shows this when at least two days exist.
struct UsageTrendCard: View {
    let days: [DailyUsageHistory.Day]
    var capturedAt: Date?

    @State private var range: TrendRange = .twoWeeks
    @State private var metric: TrendMetric = .tokens
    @State private var visibleProviders: Set<ProviderQuota.Provider> = [.claude, .codex]

    /// Most recent `range` days (or everything, if less history exists).
    private var shown: [DailyUsageHistory.Day] {
        Array(days.suffix(range.rawValue))
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "每日用量趋势", subtitle: "Claude + Codex 堆叠 · 本地 ccusage") {
                    TagPill(text: "LIVE", color: DashboardTheme.codex)
                }

                controls

                sparklineRow

                UsageTrendChart(
                    days: shown,
                    metric: metric,
                    visibleProviders: visibleProviders
                )
                    .frame(height: 208)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 12) {
            TrendLegend(visibleProviders: $visibleProviders)
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
                visibleProviders: visibleProviders
            )
        }
        if !visibleProviders.isEmpty, totals.count > 1 {
            HStack(spacing: 8) {
                Text("总量趋势")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DashboardTheme.mutedText)
                // Neutral (non-series) tint: a total is neither Claude nor Codex,
                // so it must not borrow either provider's identity color.
                DottedSparkline(values: totals, accent: DashboardTheme.secondaryText)
                    .frame(height: 20)
            }
        }
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
    let visibleProviders: Set<ProviderQuota.Provider>

    @State private var activeIndex: Int?

    private let leftGutter: CGFloat = 50
    private let xAxisHeight: CGFloat = 18
    private let segmentGap: CGFloat = 2
    private let gridlineFractions: [Double] = [0.25, 0.5, 0.75, 1.0]

    private var claudeColor: Color { DashboardTheme.providerSlots[0] }
    private var codexColor: Color { DashboardTheme.providerSlots[1] }
    private var hasVisibleSeries: Bool { !visibleProviders.isEmpty }

    private func claudeValue(_ day: DailyUsageHistory.Day) -> Double {
        guard visibleProviders.contains(.claude) else { return 0 }
        return metric == .tokens ? Double(day.claudeTokens) : day.claudeCost
    }
    private func codexValue(_ day: DailyUsageHistory.Day) -> Double {
        guard visibleProviders.contains(.codex) else { return 0 }
        return metric == .tokens ? Double(day.codexTokens) : day.codexCost
    }
    private func total(_ day: DailyUsageHistory.Day) -> Double {
        claudeValue(day) + codexValue(day)
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
                    let claudeH = barHeight(claudeValue(day), plotH: plotH)
                    let codexH = barHeight(codexValue(day), plotH: plotH)
                    let dimmed = activeIndex != nil && activeIndex != index

                    BarColumn(
                        claudeHeight: claudeH,
                        codexHeight: codexH,
                        barWidth: barW,
                        gap: segmentGap,
                        claudeColor: claudeColor,
                        codexColor: codexColor,
                        dimmed: dimmed
                    )
                    .frame(width: columnW, height: plotH)
                    .position(x: centerX, y: plotH / 2)
                    .accessibilityLabel(accessibilityLabel(for: day))

                    xLabel(index: index, day: day, centerX: centerX, y: plotH)
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
                    Text("点击图例显示用量")
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
            .animation(.easeOut(duration: 0.18), value: visibleProviders)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            hasVisibleSeries ? "每日用量堆叠柱状图" : "每日用量柱状图，未选择服务商"
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
        let stackTop = plotH - barHeight(total(day), plotH: plotH) - (codexValue(day) > 0 ? segmentGap : 0)
        let y = Swift.max(46, stackTop - 44)

        TrendTooltip(
            title: Self.fullDayLabel(day.date),
            claude: visibleProviders.contains(.claude)
                ? valueLabel(claudeValue(day))
                : nil,
            codex: visibleProviders.contains(.codex)
                ? valueLabel(codexValue(day))
                : nil,
            total: valueLabel(total(day)),
            claudeColor: claudeColor,
            codexColor: codexColor
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
        if visibleProviders.contains(.claude) {
            parts.append("Claude \(valueLabel(claudeValue(day)))")
        }
        if visibleProviders.contains(.codex) {
            parts.append("Codex \(valueLabel(codexValue(day)))")
        }
        if hasVisibleSeries {
            parts.append("共 \(valueLabel(total(day)))")
        } else {
            parts.append("未选择服务商")
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
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    static func selectedTotal(
        _ day: DailyUsageHistory.Day,
        metric: TrendMetric,
        visibleProviders: Set<ProviderQuota.Provider>
    ) -> Double {
        visibleProviders.reduce(0) { total, provider in
            switch metric {
            case .tokens:
                return total + Double(day.tokens(for: provider))
            case .cost:
                return total + day.cost(for: provider)
            }
        }
    }
}

// MARK: - Bar column

/// One day's stacked bar. Claude anchors to the baseline; Codex sits above with
/// a canvas-colored gap. Only the topmost non-zero segment rounds its top (the
/// data-end), matching the pixel segment aesthetic; zero values draw nothing.
private struct BarColumn: View {
    let claudeHeight: CGFloat
    let codexHeight: CGFloat
    let barWidth: CGFloat
    let gap: CGFloat
    let claudeColor: Color
    let codexColor: Color
    let dimmed: Bool

    private var claudeIsTop: Bool { codexHeight <= 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            if claudeHeight > 0 {
                segment(rounded: claudeIsTop)
                    .fill(claudeColor.opacity(dimmed ? 0.4 : 1))
                    .frame(width: barWidth, height: claudeHeight)
            }
            if codexHeight > 0 {
                segment(rounded: true)
                    .fill(codexColor.opacity(dimmed ? 0.4 : 1))
                    .frame(width: barWidth, height: codexHeight)
                    .offset(y: -(claudeHeight + (claudeHeight > 0 ? gap : 0)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .ignore)
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

/// Interactive two-series legend. Each provider toggles independently, including
/// the valid states where one or neither provider is visible.
struct TrendLegend: View {
    @Binding var visibleProviders: Set<ProviderQuota.Provider>

    var body: some View {
        HStack(spacing: 14) {
            item(provider: .claude, name: "Claude", color: DashboardTheme.providerSlots[0])
            item(provider: .codex, name: "Codex", color: DashboardTheme.providerSlots[1])
        }
    }

    private func item(provider: ProviderQuota.Provider, name: String, color: Color) -> some View {
        let isVisible = visibleProviders.contains(provider)
        return Button {
            if isVisible {
                visibleProviders.remove(provider)
            } else {
                visibleProviders.insert(provider)
            }
        } label: {
            HStack(spacing: 5) {
                BrandIcon(provider: provider)
                    .foregroundStyle(color)
                    .frame(width: 11, height: 11)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        isVisible ? DashboardTheme.secondaryText : DashboardTheme.mutedText
                    )
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isVisible ? color : DashboardTheme.surface2)
                    .frame(width: 12, height: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(
                                isVisible ? Color.clear : DashboardTheme.mutedText,
                                lineWidth: 1
                            )
                    )
            }
            .opacity(isVisible ? 1 : 0.42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isVisible ? "隐藏 \(name) 用量" : "显示 \(name) 用量")
        .accessibilityLabel("\(name) 图例")
        .accessibilityValue(isVisible ? "已显示" : "已隐藏")
        .accessibilityAddTraits(isVisible ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Tooltip

private struct TrendTooltip: View {
    let title: String
    let claude: String?
    let codex: String?
    let total: String
    let claudeColor: Color
    let codexColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DashboardTheme.text)
            if let claude {
                row(color: claudeColor, name: "Claude", value: claude)
            }
            if let codex {
                row(color: codexColor, name: "Codex", value: codex)
            }
            Divider().overlay(DashboardTheme.border)
            HStack {
                Text("共")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.secondaryText)
                Spacer(minLength: 8)
                Text(total)
                    .numericFont(10, .bold)
                    .foregroundStyle(DashboardTheme.text)
            }
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
