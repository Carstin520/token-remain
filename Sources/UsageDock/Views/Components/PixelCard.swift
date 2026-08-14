import SwiftUI

/// Decorative pixel-tech corner ticks plus a small dot cluster, drawn as an
/// integral-pixel `Canvas` overlay. Ornament only — hidden from accessibility.
/// Layered on card surfaces (both the macOS 26 glass path and the pre-26 flat
/// `PixelCard` fallback) to carry the mobile TokenRemain identity onto desktop.
struct PixelTickOverlay: View {
    var color: Color = DashboardTheme.border
    /// Card corner the ticks must sit inside. Continuous rounded rects cut
    /// deeper than circular ones of the same token, so the inset is derived
    /// from this rather than a fixed 5pt that gets clipped into a nub.
    var cornerRadius: CGFloat = 8
    /// Length of each L-mark arm.
    var armLength: CGFloat = 3

    var inset: CGFloat {
        Self.inset(cornerRadius: cornerRadius, armLength: armLength)
    }

    /// Distance from the card edge so the L's outer vertex stays inside a
    /// continuous rounded corner plus the card stroke.
    static func inset(
        cornerRadius: CGFloat,
        armLength: CGFloat = 3,
        strokeWidth: CGFloat = 1.5
    ) -> CGFloat {
        let radius = max(0, cornerRadius)
        let arm = max(0, armLength)
        let stroke = max(0, strokeWidth)
        // Continuous corners reach farther inward than circular. Treat the
        // curve as ~1.5× the circular diagonal inset, then add the stroke
        // and 1pt of air so the full L is visible inside the rim.
        let continuousCurveInset = radius * (1 - 1 / CGFloat(2).squareRoot()) * 1.5
        let minimum = max(5, arm + 2)
        return max(minimum, (continuousCurveInset + stroke + 1).rounded(.up))
    }

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

            // 2×2 cluster just inside the L. A short gap keeps a larger
            // corner-safe inset from walking the dots into card content.
            let clusterGap: CGFloat = 4
            let bx = size.width - i - clusterGap
            let by = size.height - i - clusterGap
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
    /// Pixel-tech tick ornament. The L sits inside the continuous corner; the
    /// clip is only an overflow fence along the inner face of the stroke, so
    /// it cannot turn a correctly placed tick into a nub on the rim.
    func pixelTicks(cornerRadius: CGFloat, color: Color = DashboardTheme.border) -> some View {
        overlay(
            PixelTickOverlay(color: color, cornerRadius: cornerRadius)
                .clipShape(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .inset(by: 0.5)
                )
        )
    }
}
