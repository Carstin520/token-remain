import SwiftUI

/// Shared panel surface. macOS 26 uses native Liquid Glass; older systems keep
/// the existing bordered dark card.
struct DashboardCard<Content: View>: View {
    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 15
    var background: Color = DashboardTheme.surface
    /// Menu-bar popup cards only. The Dashboard window is a dense grid of
    /// panels where a per-panel pointer response would be constant noise; the
    /// popup's cards are few, large and sit on glass, where the same response
    /// reads as the surface picking up the pointer.
    var interactive: Bool = false
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.usageDockPopoverGlassStyle)
    private var popoverGlassStyle
    @State private var isPointerInside = false

    var body: some View {
        pointerResponse(
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .usageDockGlassSurface(
                    cornerRadius: cornerRadius,
                    interactive: interactive,
                    fallbackBackground: background
                )
        )
        .pixelTicks(cornerRadius: cornerRadius)
    }

    /// `Glass.interactive()` is applied to the surface as well, but its
    /// response is defined against the native untinted material and the popup's
    /// cards carry a dark ink tint on top of it — measured on both styles, the
    /// effect does not survive that. This lift is the guaranteed half of the
    /// pair: a plain brighten, unmistakable in both glass styles and on the
    /// pre-26 fallback surface. A press happens with the pointer already
    /// inside, so one highlighted state covers hover and press alike.
    @ViewBuilder
    private func pointerResponse(_ card: some View) -> some View {
        if interactive {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            card
                .overlay {
                    // macOS 26 only: pre-26 cards are a flat dark surface with
                    // no glass to compose against, and their fallback path is
                    // deliberately left as it shipped.
                    if #available(macOS 26.0, *) {
                        shape
                            .fill(
                                Color.white.opacity(
                                    isPointerInside
                                        ? UsageDockPopoverAppearance.surfaceHighlightLift(
                                            glassStyle: popoverGlassStyle
                                        )
                                        : 0
                                )
                            )
                            .allowsHitTesting(false)
                    }
                }
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(
                            duration: UsageDockPopoverAppearance
                                .surfaceHighlightTransitionDuration
                        ),
                    value: isPointerInside
                )
                // A card is mostly empty space between its labels, and hover
                // tracking follows the hit-test shape, not the drawn frame —
                // without this the highlight only appeared over the text.
                .contentShape(shape)
                .onHover { isPointerInside = $0 }
        } else {
            card
        }
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
