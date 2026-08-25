import Foundation
import Testing
@testable import UsageDock

/// The Dashboard's background-lightness preference is a pure color mapping, so
/// it is testable without rendering: these cover the two promises the design
/// makes — the layer stack never collapses, and the text tiers stay readable at
/// the top of the slider's travel.
@Suite("Dashboard surface palette")
struct DashboardSurfacePaletteTests {
    private typealias Lightening = DashboardSurfaceLightening

    /// Ordered from the window ground up. Every assertion about hierarchy is
    /// written against this order.
    private let stack: [DashboardSurfaceRole] = [.canvas, .surface, .surface2, .surface3]

    private func luminance(_ role: DashboardSurfaceRole, _ lightness: Double) -> Double {
        Lightening.relativeLuminance(
            of: Lightening.lightenedComponents(role.baseHex, lightness: lightness)
        )
    }

    @Test("Lightness 0 is byte-for-byte the shipped dark palette")
    func zeroLightnessIsUnchanged() {
        for role in DashboardSurfaceRole.allCases {
            let base = Lightening.components(ofHex: role.baseHex)
            let mapped = Lightening.lightenedComponents(role.baseHex, lightness: 0)
            #expect(mapped.red == base.red)
            #expect(mapped.green == base.green)
            #expect(mapped.blue == base.blue)
        }
        #expect(DashboardSurfacePalette.dark.lightness == 0)
    }

    @Test("The maximum lightness lands on the documented blend, not the raw slider")
    func blendIsCappedAndClamped() {
        #expect(Lightening.blend(forLightness: 0) == 0)
        #expect(Lightening.blend(forLightness: 1) == Lightening.maximumBlend)
        #expect(Lightening.blend(forLightness: 0.5) == Lightening.maximumBlend / 2)
        // Out-of-range and non-finite input can only come from a corrupted
        // defaults value; it must never paint an unexpected surface.
        #expect(Lightening.blend(forLightness: 9) == Lightening.maximumBlend)
        #expect(Lightening.blend(forLightness: -4) == 0)
        #expect(Lightening.blend(forLightness: .nan) == 0)
        #expect(DashboardSurfacePalette(lightness: .infinity).lightness == 0)
        #expect(DashboardSurfacePalette(lightness: 3).lightness == 1)
    }

    @Test("The layer stack keeps its order at every slider position")
    func layerOrderIsPreserved() {
        for step in 0...20 {
            let lightness = Double(step) / 20
            let luminances = stack.map { luminance($0, lightness) }
            for index in 1..<luminances.count {
                #expect(
                    luminances[index] > luminances[index - 1],
                    "canvas < surface < surface2 < surface3 broke at lightness \(lightness)"
                )
            }
            // The border has to stay the lightest line on the card, and the
            // empty meter track has to stay between the raised surface and it.
            #expect(luminance(.track, lightness) > luminances[luminances.count - 1])
            #expect(luminance(.border, lightness) > luminance(.track, lightness))
        }
    }

    @Test("Every layer only ever gets lighter as the slider moves right")
    func lighteningIsMonotonic() {
        for role in DashboardSurfaceRole.allCases {
            var previous = luminance(role, 0)
            for step in 1...20 {
                let current = luminance(role, Double(step) / 20)
                #expect(current > previous, "\(role) stalled at step \(step)")
                previous = current
            }
        }
    }

    @Test("The neutral the surfaces travel toward is a cool grey, not the brand violet")
    func targetIsANeutralCoolGrey() {
        let target = Lightening.components(ofHex: Lightening.neutralTargetHex)
        // Blue ≥ green ≥ red is what makes it read cool; the spread is what
        // keeps it a neutral rather than a tint.
        #expect(target.blue > target.red)
        #expect(target.green > target.red)
        #expect(target.blue - target.red < 0.10)
    }

    @Test("Primary and secondary text stay readable at maximum lightness")
    func textTiersSurviveTheLightestBackground() {
        for role in stack {
            let primary = Lightening.contrastRatio(
                foregroundHex: DashboardTheme.textHex,
                surfaceHex: role.baseHex,
                lightness: 1
            )
            let secondary = Lightening.contrastRatio(
                foregroundHex: DashboardTheme.secondaryTextHex,
                surfaceHex: role.baseHex,
                lightness: 1
            )
            #expect(primary >= 7, "primary text fell to \(primary) on \(role)")
            #expect(secondary >= 4.5, "secondary text fell to \(secondary) on \(role)")
        }
    }

    /// `secondaryText` on the lightest raised surface is what sets
    /// `maximumBlend`. If someone raises the cap, this is the test that says
    /// why they cannot: the ink is fixed, so the background range has to give.
    @Test("The blend cap is the binding readability constraint")
    func capIsSetBySecondaryTextOnTheRaisedSurface() {
        let atCap = Lightening.contrastRatio(
            foregroundHex: DashboardTheme.secondaryTextHex,
            surfaceHex: DashboardSurfaceRole.surface3.baseHex,
            lightness: 1
        )
        #expect(atCap >= 4.5)
        #expect(atCap < 5.0, "the cap has drifted far below the readability budget")
        #expect(Lightening.maximumBlend <= 0.25)
    }

    @Test("Contrast only degrades gracefully — never inverts")
    func contrastDecreasesWithLightness() {
        var previous = Double.greatestFiniteMagnitude
        for step in 0...10 {
            let ratio = Lightening.contrastRatio(
                foregroundHex: DashboardTheme.textHex,
                surfaceHex: DashboardSurfaceRole.canvas.baseHex,
                lightness: Double(step) / 10
            )
            #expect(ratio < previous)
            #expect(ratio >= 7)
            previous = ratio
        }
    }
}
