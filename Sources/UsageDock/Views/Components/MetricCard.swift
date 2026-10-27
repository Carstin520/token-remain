import SwiftUI

/// KPI tile: a small label, a large mono value and an optional colored caption.
/// Used in the Dashboard Overview stat row.
struct MetricCard: View {
    let label: String
    let value: String
    var caption: String?
    var captionColor: Color = DashboardTheme.success
    var valueColor: Color = DashboardTheme.text
    /// Where an aggregate value comes from, e.g. which provider window the
    /// lowest remaining quota belongs to. It takes the caption row and the
    /// caption moves beside the value, so the tile keeps the same three rows
    /// as its neighbours.
    var source: Source?

    struct Source {
        let provider: ProviderQuota.Provider
        let text: String
    }

    var body: some View {
        DashboardCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(value)
                        .numericFont(20, .semibold)
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .layoutPriority(1)
                    if source != nil, let caption {
                        captionText(caption)
                    }
                }
                .padding(.top, 8)
                if let source {
                    sourceRow(source)
                        .padding(.top, 5)
                } else if let caption {
                    captionText(caption)
                        .padding(.top, 5)
                }
            }
            // Fills the row height so a wrapped source line keeps all four
            // tiles the same size instead of leaving its neighbours short.
            .frame(maxWidth: .infinity, minHeight: 62, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(
            [value, caption, source?.text]
                .compactMap { $0 }
                .joined(separator: L10n.text("common.list_separator"))
        )
    }

    private func captionText(_ caption: String) -> some View {
        Text(caption)
            .font(.system(size: 10))
            .foregroundStyle(captionColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func sourceRow(_ source: Source) -> some View {
        HStack(alignment: .top, spacing: 5) {
            BrandIcon(provider: source.provider)
                .frame(width: 11, height: 11)
                .padding(.top, 0.5)
            Text(source.text)
                .font(.system(size: 10))
                .foregroundStyle(DashboardTheme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
