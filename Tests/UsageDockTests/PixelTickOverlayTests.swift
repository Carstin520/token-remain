import Foundation
import Testing
@testable import UsageDock

@Suite("Pixel tick overlay")
struct PixelTickOverlayTests {
    /// A conservative stand-in for Apple's continuous corner: treat it as a
    /// circular corner 1.5× the token radius. A point on the diagonal is
    /// inside when its distance from the corner center is ≤ that radius.
    private func isInsideContinuousCorner(
        inset: CGFloat,
        cornerRadius: CGFloat
    ) -> Bool {
        let effectiveRadius = cornerRadius * 1.5
        guard inset < effectiveRadius else { return true }
        let delta = inset - effectiveRadius
        return (delta * delta) * 2 <= effectiveRadius * effectiveRadius
    }

    @Test("Fixed 5pt inset sits on a 13pt feed-card curve")
    func legacyFeedCardInsetIsClipped() {
        #expect(!isInsideContinuousCorner(inset: 5, cornerRadius: 13))
    }

    @Test("Derived inset keeps the L inside a 13pt feed-card corner")
    func feedCardInsetClearsContinuousCurve() {
        let inset = PixelTickOverlay.inset(cornerRadius: 13)
        #expect(inset > 5)
        #expect(isInsideContinuousCorner(inset: inset, cornerRadius: 13))
    }

    @Test("Derived inset keeps the L inside every production card radius")
    func productionCardRadiiClearContinuousCurve() {
        // AIFeedPostCard / RiskStrip = 13, MetricCard = 14, DashboardCard = 15.
        for radius in [13, 14, 15] as [CGFloat] {
            let inset = PixelTickOverlay.inset(cornerRadius: radius)
            #expect(inset > 5)
            #expect(isInsideContinuousCorner(inset: inset, cornerRadius: radius))
        }
    }

    @Test("Inset grows with corner radius and never drops below 5pt")
    func insetScalesWithRadius() {
        #expect(PixelTickOverlay.inset(cornerRadius: 0) == 5)
        #expect(PixelTickOverlay.inset(cornerRadius: 8) >= 5)
        #expect(
            PixelTickOverlay.inset(cornerRadius: 15)
                > PixelTickOverlay.inset(cornerRadius: 8)
        )
    }
}
