import Charts
import SwiftUI
import TokenRemainKit
import TokenRemainSyncKit

/// Mirrors the desktop Trends contract: real daily `ccusage` aggregates,
/// rendered as Claude + Codex stacked bars. Quota observation points remain a
/// separate local-only concern and are never promoted into invented daily data.
struct TrendsTab: View {
    @Environment(AppModel.self) private var model
    @State private var range: MobileTrendRange = .seven
    @State private var metric: MobileTrendMetric = .tokens
    /// The day key (`yyyy-MM-dd`) the user scrubbed to on the chart, if any.
    /// `nil` means the readout defaults to the most recent day.
    @State private var selectedDay: String?

    private var days: [SyncedDailyUsageDay] {
        Array((model.dailyUsageHistory?.days ?? []).suffix(range.dayCount))
    }

    /// The day whose breakdown the readout shows: the scrubbed selection when it
    /// falls inside the current range, otherwise the most recent day.
    private var readoutDay: SyncedDailyUsageDay? {
        if let selectedDay, let match = days.first(where: { $0.day == selectedDay }) {
            return match
        }
        return days.last
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    CyberPageHeader(title: TRL10n.t("tab.trends"))
                    DemoHeaderRow()
                    if days.count < 2 {
                        emptyState
                    } else {
                        chartCard
                        totalsCard
                        metadataCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 96)
            }
            .background(TRTheme.ink)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var emptyState: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(TRL10n.t("trends.empty.title"))
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(TRTheme.text)
                Text(TRL10n.t("trends.empty"))
                    .font(.footnote)
                    .foregroundStyle(TRTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cyberCard()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tr.trends.emptyState")
        .accessibilityLabel(TRL10n.t("trends.empty"))
    }

    private var chartCard: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(TRL10n.t("trends.title.usage"))
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(TRTheme.text)
                    Text(TRL10n.t("trends.subtitle.usage"))
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                }
                controls
                providerLegend
                daySummary
                stackedBarChart
                    .frame(height: 230)
                    // The identifier lives on the chart itself, not the whole card —
                    // a card-level identifier propagates onto every descendant and
                    // would shadow the readout's own `tr.trends.selectionCallout`.
                    .accessibilityIdentifier("tr.trends.usageBarChart")
            }
        }
        .cyberCard()
        // A selection that falls outside a newly-chosen range would just be ignored,
        // but clearing it keeps the readout's "latest day" default honest.
        .onChange(of: range) { _, _ in selectedDay = nil }
    }

    /// A compact, always-present readout above the chart. It shows the most recent
    /// day by default (so the latest split is glanceable) and switches to whichever
    /// day the user scrubs to — the chart's selection feedback in a readable form.
    @ViewBuilder
    private var daySummary: some View {
        if let day = readoutDay {
            let isSelected = selectedDay != nil && days.contains { $0.day == selectedDay }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(shortDay(day.day))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(TRTheme.text)
                    Text(isSelected
                        ? TRL10n.t("trends.readout.selected")
                        : TRL10n.t("trends.readout.latest"))
                        .font(.caption2)
                        .foregroundStyle(TRTheme.textMute)
                    Spacer(minLength: 8)
                    Text(valueLabel(value(for: day, provider: .claude) + value(for: day, provider: .codex)))
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold).monospacedDigit())
                        .foregroundStyle(TRTheme.text)
                }
                TRAdaptiveRow(spacing: 14) {
                    readoutPill("Claude", value: value(for: day, provider: .claude), color: TRTheme.claudeAccent)
                    readoutPill("Codex", value: value(for: day, provider: .codex), color: TRTheme.codexAccent)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TRTheme.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("tr.trends.selectionCallout")
            .accessibilityLabel(readoutAccessibilityLabel(day, isSelected: isSelected))
        }
    }

    private func readoutPill(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
            Text(valueLabel(value))
                .font(.system(.caption, design: .monospaced, weight: .semibold).monospacedDigit())
                .foregroundStyle(TRTheme.text)
        }
    }

    private func readoutAccessibilityLabel(_ day: SyncedDailyUsageDay, isSelected: Bool) -> String {
        let prefix = isSelected
            ? TRL10n.t("trends.readout.selected")
            : TRL10n.t("trends.readout.latest")
        return TRL10n.f(
            "trends.readout.a11y",
            "\(prefix) \(shortDay(day.day))",
            valueLabel(value(for: day, provider: .claude)),
            valueLabel(value(for: day, provider: .codex))
        )
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker(TRL10n.t("trends.range"), selection: $range) {
                ForEach(MobileTrendRange.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)

            Picker(TRL10n.t("trends.metric"), selection: $metric) {
                ForEach(MobileTrendMetric.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var providerLegend: some View {
        HStack(spacing: 16) {
            legendItem("Claude", color: TRTheme.claudeAccent)
            legendItem("Codex", color: TRTheme.codexAccent)
            Spacer()
        }
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 14, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(TRTheme.textDim)
        }
    }

    private var stackedBarChart: some View {
        Chart {
            ForEach(days) { day in
                BarMark(
                    x: .value("Day", day.day),
                    y: .value("Claude", value(for: day, provider: .claude))
                )
                .foregroundStyle(by: .value("Provider", "Claude"))
                .cornerRadius(2)

                BarMark(
                    x: .value("Day", day.day),
                    y: .value("Codex", value(for: day, provider: .codex))
                )
                .foregroundStyle(by: .value("Provider", "Codex"))
                .cornerRadius(2)
            }

            // A dashed pointer marks the scrubbed column; the readable breakdown
            // lives in the `daySummary` above so it never overlaps the bars.
            if let selectedDay, days.contains(where: { $0.day == selectedDay }) {
                RuleMark(x: .value("Day", selectedDay))
                    .foregroundStyle(TRTheme.text.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(
            domain: ["Claude", "Codex"],
            range: [TRTheme.claudeAccent, TRTheme.codexAccent]
        )
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedDay)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(TRTheme.border.opacity(0.7))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(axisLabel(raw))
                            .foregroundStyle(TRTheme.textDim)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(days.count, 7))) { value in
                AxisGridLine().foregroundStyle(TRTheme.border.opacity(0.5))
                AxisValueLabel {
                    if let day = value.as(String.self) {
                        Text(shortDay(day))
                            .foregroundStyle(TRTheme.textDim)
                    }
                }
            }
        }
        .accessibilityLabel(
            TRL10n.f("trends.chart.a11y", days.count, metric.label)
        )
    }

    private var totalsCard: some View {
        PixelCard(padding: 12) {
            VStack(spacing: 8) {
                HStack {
                    Text(TRL10n.f("trends.totals.title", days.count))
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                    Spacer(minLength: 0)
                }
                metricRow(
                    title: "Claude",
                    value: total(for: .claude),
                    color: TRTheme.claudeAccent
                )
                Divider().overlay(TRTheme.border)
                metricRow(
                    title: "Codex",
                    value: total(for: .codex),
                    color: TRTheme.codexAccent
                )
                Divider().overlay(TRTheme.border)
                combinedTotalRow
            }
        }
        .cyberCard()
        .accessibilityIdentifier("tr.trends.totals")
    }

    private var combinedTotalRow: some View {
        HStack {
            Text(TRL10n.t("trends.totals.combined"))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
            Spacer()
            Text(valueLabel(total(for: .claude) + total(for: .codex)))
                .font(.system(.subheadline, design: .monospaced, weight: .bold).monospacedDigit())
                .foregroundStyle(TRTheme.text)
                .accessibilityLabel(accessibleValueLabel(total(for: .claude) + total(for: .codex)))
        }
    }

    private func metricRow(
        title: String,
        value: Double,
        color: Color
    ) -> some View {
        HStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(TRTheme.text)
            Spacer()
            Text(valueLabel(value))
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(TRTheme.text)
                .accessibilityLabel(accessibleValueLabel(value))
        }
    }

    private var metadataCard: some View {
        PixelCard(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(TRL10n.f("trends.meta.days", model.dailyUsageHistory?.days.count ?? 0))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textDim)
                if let capturedAt = model.dailyUsageHistory?.capturedAt {
                    Text(TRL10n.f(
                        "trends.meta.captured",
                        UsageFormatting.freshnessDescription(since: capturedAt, now: Date())
                    ))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textDim)
                }
                Text(TRL10n.t("trends.privacy"))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cyberCard()
        .accessibilityIdentifier("tr.trends.metadata")
    }

    private func value(
        for day: SyncedDailyUsageDay,
        provider: ProviderQuota.Provider
    ) -> Double {
        switch (metric, provider) {
        case (.tokens, .claude): Double(day.claudeTokens)
        case (.tokens, .codex): Double(day.codexTokens)
        case (.cost, .claude): day.claudeCost
        case (.cost, .codex): day.codexCost
        default: 0
        }
    }

    private func total(for provider: ProviderQuota.Provider) -> Double {
        days.reduce(0) { $0 + value(for: $1, provider: provider) }
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .tokens:
            switch value {
            case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
            case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
            case 1_000...: return String(format: "%.0fK", value / 1_000)
            default: return String(format: "%.0f", value)
            }
        case .cost:
            return value >= 1_000
                ? String(format: "$%.1fK", value / 1_000)
                : String(format: "$%.0f", value)
        }
    }

    private func valueLabel(_ value: Double) -> String {
        metric == .tokens
            ? axisLabel(value)
            : String(format: "$%.2f", value)
    }

    private func accessibleValueLabel(_ value: Double) -> String {
        switch metric {
        case .tokens:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            let fullValue = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
            return TRL10n.f("trends.value.tokens.a11y", fullValue)
        case .cost:
            return TRL10n.f("trends.value.cost.a11y", String(format: "%.2f", value))
        }
    }

    private func shortDay(_ value: String) -> String {
        String(value.dropFirst(5)).replacingOccurrences(of: "-", with: "/")
    }
}

private enum MobileTrendRange: Int, CaseIterable, Identifiable {
    case seven = 7
    case fourteen = 14
    case thirty = 30

    var id: Int { rawValue }
    var dayCount: Int { rawValue }
    var label: String { "\(rawValue)" }
}

private enum MobileTrendMetric: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: String { rawValue }
    var label: String {
        switch self {
        case .tokens: TRL10n.t("trends.metric.tokens")
        case .cost: TRL10n.t("trends.metric.cost")
        }
    }
}

#Preview("Trends") {
    TrendsTab()
        .environment(AppModel(arguments: ["-tr-demo", "concept"]))
        .preferredColorScheme(.dark)
}
