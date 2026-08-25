import SwiftUI

/// A provider-per-row percentage trend. Provider windows are intentionally not
/// overlaid or stacked because their durations differ.
struct QuotaConsumptionTrendCard: View {
    let history: QuotaUsageHistory
    let enabledProviders: [ProviderQuota.Provider]

    @State private var range: TrendRange = .week

    private var cutoff: Date {
        Calendar.current.date(byAdding: .day, value: -range.rawValue, to: .now) ?? .distantPast
    }

    private var rows: [QuotaTrendRowData] {
        enabledProviders.compactMap { provider in
            let samples = history.samples(for: provider, since: cutoff)
            guard !samples.isEmpty else { return nil }
            return QuotaTrendRowData(provider: provider, samples: samples)
        }
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(
                    title: L10n.text("trends.quota_title"),
                    subtitle: L10n.text("trends.quota_subtitle")
                ) {
                    PixelSegmentedControl(
                        options: TrendRange.allCases.map { ($0, $0.label) },
                        selection: $range
                    )
                }

                if rows.isEmpty {
                    EmptyStateView(
                        icon: "chart.xyaxis.line",
                        title: L10n.text("trends.quota_accumulating_title"),
                        message: L10n.text("trends.quota_accumulating_message")
                    )
                    .frame(maxWidth: .infinity, minHeight: 92)
                } else {
                    headerRow
                    Divider().overlay(DashboardSurface.border)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        QuotaTrendRow(row: row, cutoff: cutoff)
                        if index != rows.count - 1 {
                            Divider().overlay(DashboardSurface.border.opacity(0.65))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var headerRow: some View {
        HStack(spacing: 14) {
            Text(L10n.text("trends.quota_provider"))
                .frame(width: 138, alignment: .leading)
            Text(L10n.text("trends.quota_window"))
                .frame(width: 76, alignment: .leading)
            Text(L10n.text("trends.quota_used"))
                .frame(width: 66, alignment: .trailing)
            Text(L10n.text("trends.quota_history"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(DashboardTheme.Typo.mono(9))
        .foregroundStyle(DashboardTheme.mutedText)
        .textCase(.uppercase)
        .accessibilityHidden(true)
    }
}

struct QuotaTrendRowData: Identifiable {
    let provider: ProviderQuota.Provider
    let samples: [QuotaUsageHistory.Sample]

    var id: ProviderQuota.Provider { provider }
    var latest: QuotaUsageHistory.Sample { samples[samples.count - 1] }
    var displayName: String {
        latest.attribution.map { "\(provider.displayName) · \($0.displayName)" }
            ?? provider.displayName
    }
    var accentProvider: ProviderQuota.Provider {
        latest.attribution?.provider ?? provider
    }
}

private struct QuotaTrendRow: View {
    let row: QuotaTrendRowData
    let cutoff: Date

    private var color: Color { DashboardTheme.accent(for: row.accentProvider) }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                BrandIcon(provider: row.provider)
                    .foregroundStyle(color)
                    .frame(width: 16, height: 16)
                Text(row.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
            }
            .frame(width: 138, alignment: .leading)

            Text(UsageFormatting.windowName(minutes: row.latest.windowMinutes))
                .font(.system(size: 10))
                .foregroundStyle(DashboardTheme.secondaryText)
                .frame(width: 76, alignment: .leading)

            Text(UsageFormatting.percent(row.latest.usedPercent))
                .numericFont(11, .bold)
                .foregroundStyle(color)
                .frame(width: 66, alignment: .trailing)

            QuotaPercentageSparkline(
                samples: row.samples,
                cutoff: cutoff,
                color: color
            )
            .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format(
                "trends.quota_row_accessibility",
                row.displayName,
                UsageFormatting.windowName(minutes: row.latest.windowMinutes),
                UsageFormatting.percent(row.latest.usedPercent)
            )
        )
    }
}

/// Fixed 0...100% y-axis; x positions use the selected time range so rows can
/// be compared without implying that their quota windows are equivalent.
struct QuotaPercentageSparkline: View {
    let samples: [QuotaUsageHistory.Sample]
    let cutoff: Date
    let color: Color

    /// `Canvas` paints raw colors, so the grid resolves the palette here rather
    /// than through a `ShapeStyle`.
    @Environment(\.dashboardSurfaces)
    private var surfaces

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Canvas { graphics, size in
                drawGrid(in: &graphics, size: size)
                drawTrend(in: &graphics, size: size, now: context.date)
            }
        }
        .accessibilityHidden(true)
    }

    private func drawGrid(in graphics: inout GraphicsContext, size: CGSize) {
        for fraction in [0.0, 0.5, 1.0] {
            var path = Path()
            let y = size.height * fraction
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            graphics.stroke(path, with: .color(surfaces.border.opacity(0.45)), lineWidth: 1)
        }
    }

    private func drawTrend(in graphics: inout GraphicsContext, size: CGSize, now: Date) {
        let duration = max(1, now.timeIntervalSince(cutoff))
        let points = samples.map { sample in
            CGPoint(
                x: size.width * CGFloat(min(1, max(0, sample.capturedAt.timeIntervalSince(cutoff) / duration))),
                y: size.height * CGFloat(1 - min(100, max(0, sample.usedPercent)) / 100)
            )
        }
        guard let first = points.first else { return }

        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if points.count > 1 {
            graphics.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
            )
        }

        let latest = points[points.count - 1]
        graphics.fill(
            Path(ellipseIn: CGRect(x: latest.x - 2.5, y: latest.y - 2.5, width: 5, height: 5)),
            with: .color(color)
        )
    }
}
