import Charts
import SwiftUI
import TokenRemainKit

/// Renders **only** history this device has actually recorded. There is no
/// server-side series to backfill from, so an empty store shows an empty state
/// rather than an invented curve.
struct TrendsTab: View {
    @Environment(AppModel.self) private var model

    private var window: [SnapshotHistoryPoint] {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        return model.history.filter { $0.generatedAt >= cutoff }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    DemoHeaderRow()
                    if window.count < 2 {
                        emptyState
                    } else {
                        minRemainingChart
                        providerChart
                        metadataCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(TRTheme.ink)
            .navigationTitle(TRL10n.t("tab.trends"))
        }
    }

    private var emptyState: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(TRL10n.t("overview.trend.empty"))
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(TRTheme.text)
                Text(TRL10n.t("trends.empty"))
                    .font(.footnote)
                    .foregroundStyle(TRTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tr.trends.emptyState")
        .accessibilityLabel(TRL10n.t("trends.empty"))
    }

    private var minRemainingChart: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(TRL10n.t("trends.title.min"))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(TRTheme.text)
                Chart(window) { point in
                    LineMark(
                        x: .value("Date", point.generatedAt),
                        y: .value("Remaining", point.minRemainingPercent)
                    )
                    .foregroundStyle(TRTheme.violet)
                    .interpolationMethod(.linear)
                    PointMark(
                        x: .value("Date", point.generatedAt),
                        y: .value("Remaining", point.minRemainingPercent)
                    )
                    .symbolSize(6)
                    .foregroundStyle(TRTheme.violet)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { axisMarks }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine().foregroundStyle(TRTheme.border)
                    AxisValueLabel().foregroundStyle(TRTheme.textDim)
                } }
                .frame(height: 160)
            }
        }
        .accessibilityIdentifier("tr.trends.minChart")
        .accessibilityLabel(TRL10n.t("trends.title.min"))
    }

    private var providerChart: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(TRL10n.t("trends.title.provider"))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(TRTheme.text)
                Chart {
                    ForEach(ProviderQuota.Provider.allCases, id: \.self) { provider in
                        ForEach(window) { point in
                            if let value = point.perProviderRemaining[provider.rawValue] {
                                LineMark(
                                    x: .value("Date", point.generatedAt),
                                    y: .value("Remaining", value),
                                    series: .value("Provider", provider.shortName)
                                )
                                .foregroundStyle(TRTheme.accent(for: provider))
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { axisMarks }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine().foregroundStyle(TRTheme.border)
                    AxisValueLabel().foregroundStyle(TRTheme.textDim)
                } }
                .frame(height: 160)
                legend
            }
        }
        .accessibilityIdentifier("tr.trends.providerChart")
        .accessibilityLabel(TRL10n.t("trends.title.provider"))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(ProviderQuota.Provider.allCases, id: \.self) { provider in
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(TRTheme.accent(for: provider))
                        .frame(width: 8, height: 3)
                    Text(provider.shortName)
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                }
            }
        }
    }

    private var axisMarks: some AxisContent {
        AxisMarks(values: [0, 50, 100]) { _ in
            AxisGridLine().foregroundStyle(TRTheme.border)
            AxisValueLabel().foregroundStyle(TRTheme.textDim)
        }
    }

    private var metadataCard: some View {
        PixelCard(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(TRL10n.f("trends.meta.points", window.count))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textDim)
                if let earliest = window.first?.generatedAt {
                    Text(TRL10n.f("trends.meta.earliest", UsageFormatting.freshnessDescription(since: earliest, now: Date())))
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                }
                Text(TRL10n.t("trends.empty"))
                    .font(.caption)
                    .foregroundStyle(TRTheme.textMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("tr.trends.metadata")
    }
}

#Preview("Trends") {
    TrendsTab()
        .environment(AppModel(arguments: ["-tr-demo", "concept"]))
        .preferredColorScheme(.dark)
}
