import SwiftUI

/// KPI tile: a small label, a large mono value and an optional colored caption.
/// Used in the Dashboard Overview stat row.
struct MetricCard: View {
    let label: String
    let value: String
    var caption: String?
    var captionColor: Color = DashboardTheme.success
    var valueColor: Color = DashboardTheme.text

    var body: some View {
        DashboardCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.secondaryText)
                Text(value)
                    .numericFont(23, .semibold)
                    .foregroundStyle(valueColor)
                    .padding(.top, 9)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let caption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(captionColor)
                        .padding(.top, 5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, caption].compactMap { $0 }.joined(separator: L10n.text("common.list_separator")))
    }
}
