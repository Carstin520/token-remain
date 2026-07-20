import SwiftUI

/// Shared panel surface. macOS 26 uses native Liquid Glass; older systems keep
/// the existing bordered dark card.
struct DashboardCard<Content: View>: View {
    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 15
    var background: Color = DashboardTheme.surface
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .usageDockGlassSurface(
                cornerRadius: cornerRadius,
                fallbackBackground: background
            )
            .pixelTicks(cornerRadius: cornerRadius)
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

/// Small uppercase pill (plan name, LIVE badge, status tag). Now rendered with
/// the shared pixel-tech `PixelBadge` chrome so every meta tag reads as one
/// system. `background` is retained for source compatibility with existing call
/// sites; the pixel chip derives its own fill from `color`.
struct TagPill: View {
    let text: String
    var color: Color = DashboardTheme.secondaryText
    var background: Color = DashboardTheme.surface2

    var body: some View {
        PixelBadge(text: text, color: color)
    }
}
