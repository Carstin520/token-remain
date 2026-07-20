import SwiftUI

/// Decorative pixel-tech corner ticks plus a small dot cluster, drawn as an
/// integral-pixel `Canvas` overlay. Ornament only — hidden from accessibility.
/// Layered on card surfaces (both the macOS 26 glass path and the pre-26 flat
/// `PixelCard` fallback) to carry the mobile Token Remain identity onto desktop.
struct PixelTickOverlay: View {
    var color: Color = DashboardTheme.border
    /// Distance of the tick corner from the card edge.
    var inset: CGFloat = 5
    /// Length of each L-mark arm.
    var armLength: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            let a = armLength
            let i = inset

            func drawL(_ x: CGFloat, _ y: CGFloat, _ dirX: CGFloat, _ dirY: CGFloat) {
                // Horizontal arm.
                context.fill(
                    Path(CGRect(x: x, y: y, width: dirX * a, height: 1).standardized),
                    with: .color(color)
                )
                // Vertical arm.
                context.fill(
                    Path(CGRect(x: x, y: y, width: 1, height: dirY * a).standardized),
                    with: .color(color)
                )
            }

            drawL(i, i, 1, 1)                                    // top-left
            drawL(size.width - i, i, -1, 1)                     // top-right
            drawL(i, size.height - i, 1, -1)                    // bottom-left
            drawL(size.width - i, size.height - i, -1, -1)      // bottom-right

            // 2×2 dot cluster tucked inside the bottom-right corner tick.
            let bx = size.width - i - 8
            let by = size.height - i - 8
            for row in 0..<2 {
                for col in 0..<2 {
                    context.fill(
                        Path(CGRect(x: bx + CGFloat(col) * 2, y: by + CGFloat(row) * 2, width: 1, height: 1)),
                        with: .color(color)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Flat pre-macOS 26 pixel card surface: `surface` fill, 1px border, rounded
/// corners and the tick ornament. The macOS 26 path keeps system glass and adds
/// the tick overlay separately via `.pixelTicks`.
struct PixelCard<Content: View>: View {
    var cornerRadius: CGFloat = 8
    var fill: Color = DashboardTheme.surface
    var border: Color = DashboardTheme.border
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .pixelTicks(cornerRadius: cornerRadius)
    }
}

extension View {
    /// Applies the pixel-tech tick ornament clipped to the card's rounded rect.
    func pixelTicks(cornerRadius: CGFloat, color: Color = DashboardTheme.border) -> some View {
        overlay(
            PixelTickOverlay(color: color)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
    }
}
