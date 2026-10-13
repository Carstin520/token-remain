import SwiftUI

/// A single stacked bar of input / output / cache write / cache read. Each
/// non-empty kind keeps at least a hairline so a 0.4% output share is still
/// visible next to a 95% cache read share; widths stay proportional otherwise.
struct TokenCompositionBar: View {
    let composition: TokenComposition
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let parts = composition.parts.filter { $0.tokens > 0 }
            let gap: CGFloat = parts.count > 1 ? 1 : 0
            let available = max(0, geo.size.width - gap * CGFloat(max(0, parts.count - 1)))
            let widths = Self.widths(for: parts.map(\.share), available: available, minimum: 2)
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    Rectangle()
                        .fill(DashboardTheme.compositionColor(part.kind))
                        .frame(width: widths[index])
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .leading)
            .background(DashboardTheme.track)
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Proportional widths with a floor for tiny shares, taking the floor's
    /// space back from the largest segments so the bar never overflows.
    static func widths(for shares: [Double], available: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard !shares.isEmpty, available > 0 else { return shares.map { _ in 0 } }
        var widths = shares.map { CGFloat($0) * available }
        let floor = min(minimum, available / CGFloat(shares.count))
        var deficit: CGFloat = 0
        for index in widths.indices where widths[index] < floor {
            deficit += floor - widths[index]
            widths[index] = floor
        }
        let donors = widths.indices.filter { widths[$0] > floor }.sorted { widths[$0] > widths[$1] }
        for index in donors where deficit > 0 {
            let give = min(deficit, widths[index] - floor)
            widths[index] -= give
            deficit -= give
        }
        return widths
    }
}

/// The Trends card's token-mix summary: a bar plus a legend with each kind's
/// share and amount, all visible without hover (DB-002).
struct TokenCompositionStrip: View {
    let title: String
    let composition: TokenComposition

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DashboardTheme.secondaryText)
                Spacer(minLength: 8)
                Text(UsageFormatting.compactNumber(composition.total))
                    .numericFont(11, .medium)
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            TokenCompositionBar(composition: composition, height: 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { legendItems }
                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading,
                    spacing: 5
                ) { legendItems }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(TrendModelBreakdownPanel.compositionHelp(composition))
    }

    @ViewBuilder
    private var legendItems: some View {
        ForEach(composition.parts) { part in
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(DashboardTheme.compositionColor(part.kind))
                    .frame(width: 8, height: 8)
                Text(part.kind.label)
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .lineLimit(1)
                Text(Self.shareLabel(part.share))
                    .numericFont(11, .semibold)
                    .foregroundStyle(DashboardTheme.text)
                Text(UsageFormatting.compactNumber(part.tokens))
                    .numericFont(10)
                    .foregroundStyle(DashboardTheme.mutedText)
            }
            .fixedSize()
        }
    }

    /// One decimal keeps a small output share from reading as 0%.
    static func shareLabel(_ share: Double) -> String {
        let percent = share * 100
        if percent > 0, percent < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", percent)
    }
}
