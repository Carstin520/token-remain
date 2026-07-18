import SwiftUI

/// Bordered dark surface used as the base container for popover cards and
/// Dashboard panels. Keeps corner radius, border and background consistent.
struct DashboardCard<Content: View>: View {
    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 15
    var background: Color = DashboardTheme.surface
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DashboardTheme.border, lineWidth: 1)
            )
    }
}

/// Standard header for a Dashboard panel: title, optional subtitle, and an
/// optional trailing accessory (legend, pill, etc.).
struct PanelHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

/// Small uppercase pill (plan name, LIVE badge, status tag).
struct TagPill: View {
    let text: String
    var color: Color = DashboardTheme.secondaryText
    var background: Color = DashboardTheme.surface2

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
