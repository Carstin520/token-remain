import AppKit
import SwiftUI
import Testing
@testable import UsageDock

/// WCAG contrast guarantees for the pixel-tech "TokenRemain" palette. Value-
/// bearing text (`text`, `secondaryText`) must stay legible on `surface`; the
/// provider accents must clear the 3:1 non-text component threshold against
/// both the card surface and the unfilled progress track.
@Suite("Theme contrast")
struct ThemeContrastTests {
    /// WCAG 2.x relative luminance of a SwiftUI color, resolved in sRGB.
    private func luminance(_ color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(ns.redComponent)
            + 0.7152 * linear(ns.greenComponent)
            + 0.0722 * linear(ns.blueComponent)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    @Test("Primary text clears WCAG AA on surface")
    func primaryTextContrast() {
        #expect(contrast(DashboardTheme.text, DashboardTheme.surface) >= 4.5)
    }

    @Test("Secondary text clears WCAG AA on surface")
    func secondaryTextContrast() {
        #expect(contrast(DashboardTheme.secondaryText, DashboardTheme.surface) >= 4.5)
    }

    private func components(_ color: Color) -> (Double, Double, Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private func colorsMatch(_ lhs: Color, _ rhs: Color) -> Bool {
        let l = components(lhs)
        let r = components(rhs)
        return abs(l.0 - r.0) < 0.001
            && abs(l.1 - r.1) < 0.001
            && abs(l.2 - r.2) < 0.001
    }

    @Test("Every provider quota accent is visible on the dark meter")
    func providerAccentContrast() {
        var assignedAccents: [Color] = []
        for provider in ProviderQuota.Provider.displayOrder {
            let accent = DashboardTheme.accent(for: provider)
            #expect(contrast(accent, DashboardTheme.surface) >= 3.0)
            #expect(contrast(accent, DashboardTheme.track) >= 3.0)
            #expect(!colorsMatch(accent, DashboardTheme.danger))
            #expect(colorsMatch(
                DashboardTheme.quotaAccent(for: provider, remainingPercent: 50),
                accent
            ))
            for assignedAccent in assignedAccents {
                #expect(!colorsMatch(accent, assignedAccent))
            }
            assignedAccents.append(accent)
        }
    }

    @Test("Provider quota meters retain theme colors until critically low")
    func lowQuotaUsesDangerRed() {
        #expect(colorsMatch(
            DashboardTheme.quotaAccent(for: .claude, remainingPercent: 9.9),
            DashboardTheme.danger
        ))
        #expect(colorsMatch(
            DashboardTheme.quotaAccent(for: .claude, remainingPercent: 10),
            DashboardTheme.claudeAccent
        ))
        #expect(colorsMatch(
            DashboardTheme.quotaAccent(for: .codex, remainingPercent: 100),
            DashboardTheme.codexAccent
        ))
        #expect(!colorsMatch(DashboardTheme.claudeAccent, DashboardTheme.codexAccent))
    }

    @Test("TokenRemain links use the product violet")
    func productLinkAccent() {
        #expect(colorsMatch(DashboardTheme.link, DashboardTheme.violet))
    }

    /// Semantic status colors are UI components (badges/glyphs) always paired
    /// with a text label, so they are held to the 3:1 non-text component
    /// threshold rather than the 4.5:1 body-text threshold.
    @Test("Semantic status colors clear the 3:1 UI-component threshold on surface")
    func semanticStatusContrast() {
        #expect(contrast(DashboardTheme.success, DashboardTheme.surface) >= 3.0)
        #expect(contrast(DashboardTheme.warning, DashboardTheme.surface) >= 3.0)
        #expect(contrast(DashboardTheme.danger, DashboardTheme.surface) >= 3.0)
    }

    @Test("Feed priority accents keep information separate from warnings")
    func feedPrioritySemantics() {
        let quotaAccent = DashboardTheme.feedAccent(for: .tokenReset)
        let updateAccent = DashboardTheme.feedAccent(for: .majorUpdate)

        #expect(colorsMatch(quotaAccent, DashboardTheme.information))
        #expect(colorsMatch(quotaAccent, DashboardTheme.cyan))
        #expect(!colorsMatch(quotaAccent, DashboardTheme.violet))
        #expect(!colorsMatch(quotaAccent, DashboardTheme.warning))
        #expect(colorsMatch(updateAccent, DashboardTheme.violetDim))
        #expect(contrast(quotaAccent, DashboardTheme.surface) >= 3.0)
        #expect(contrast(updateAccent, DashboardTheme.surface) >= 3.0)
    }

    /// Filled badges (e.g. HIGH risk) print ink text on the status field — white
    /// fails on the red field (≈2.8:1), so the palette mandates ink. Verify ink
    /// clears WCAG AA text contrast on the warning and danger fills.
    @Test("Ink text on filled status fields clears WCAG AA")
    func inkOnFilledContrast() {
        #expect(contrast(DashboardTheme.canvas, DashboardTheme.danger) >= 4.5)
        #expect(contrast(DashboardTheme.canvas, DashboardTheme.warning) >= 4.5)
    }

    @Test("Transparent popup surfaces retain glass instead of a canvas tint")
    func transparentPopupSurfaceMapping() {
        #expect(UsageDockPopoverAppearance.backdropMaterialOpacity(
            backdropOpacity: 0
        ) == UsageDockPopoverAppearance.minimumBackdropMaterialOpacity)
        #expect(UsageDockPopoverAppearance.backdropMaterialOpacity(
            backdropOpacity: 0.62
        ) == 1)
        #expect(UsageDockPopoverAppearance.surfaceTintOpacity(backdropOpacity: 0) == 0)
        #expect(UsageDockPopoverAppearance.surfaceTintOpacity(backdropOpacity: 1) == 1)
        #expect(UsageDockPopoverAppearance.surfaceTintOpacity(backdropOpacity: -1) == 0)
        #expect(UsageDockPopoverAppearance.surfaceTintOpacity(backdropOpacity: 2) == 1)
        #expect(!UsageDockPopoverAppearance.appliesSurfaceTint(backdropOpacity: 0))
        #expect(UsageDockPopoverAppearance.appliesSurfaceTint(backdropOpacity: 0.01))
    }

    /// The regression this replaces: edge opacity was derived from the inverse
    /// of the fill, so the most transparent popup was the most heavily outlined
    /// one and read as a wireframe. Rim strength must be a property of the glass
    /// style alone.
    @Test("Popup rims never strengthen as the popup becomes more transparent")
    func rimStrengthIsIndependentOfBackdrop() {
        for style in [PopoverGlassStyle.clear, .frosted] {
            let highlight = UsageDockPopoverAppearance.shellRimHighlightOpacity(
                glassStyle: style
            )
            let shade = UsageDockPopoverAppearance.shellRimShadeOpacity(glassStyle: style)
            let surface = UsageDockPopoverAppearance.surfaceRimOpacity(glassStyle: style)

            // Well below the point where a full-perimeter stroke reads as a
            // drawn outline rather than a lit edge.
            #expect(highlight > 0 && highlight <= 0.35)
            #expect(shade > 0 && shade <= 0.30)
            // Cards sit on the shell, so their edge stays weaker than the
            // shell's, which has to survive the desktop behind it.
            #expect(surface > 0 && surface < highlight)
        }

        // Frosted's material floor already separates it, so it carries less rim.
        #expect(
            UsageDockPopoverAppearance.shellRimHighlightOpacity(glassStyle: .clear)
                > UsageDockPopoverAppearance.shellRimHighlightOpacity(glassStyle: .frosted)
        )
        #expect(
            UsageDockPopoverAppearance.surfaceRimOpacity(glassStyle: .clear)
                > UsageDockPopoverAppearance.surfaceRimOpacity(glassStyle: .frosted)
        )
    }

    /// A transparent card keeps a white *lift* instead of a canvas tint: tinting
    /// toward the dark canvas is what previously made Clear cards near-black,
    /// and no lift at all left the card as an empty outline.
    @Test("Transparent cards keep a light material floor that hands off to the tint")
    func surfaceLiftHandsOffToTint() {
        #expect(
            UsageDockPopoverAppearance.surfaceLiftOpacity(backdropOpacity: 0)
                == UsageDockPopoverAppearance.minimumSurfaceLift
        )
        #expect(UsageDockPopoverAppearance.minimumSurfaceLift < 0.1)
        // Fully handed off once the ink tint reaches its reference strength, so
        // the two never stack into a muddy surface.
        #expect(
            UsageDockPopoverAppearance.surfaceLiftOpacity(
                backdropOpacity: UsageDockPopoverAppearance.referenceBackdropOpacity
            ) == 0
        )
        #expect(UsageDockPopoverAppearance.surfaceLiftOpacity(backdropOpacity: 1) == 0)
        #expect(UsageDockPopoverAppearance.surfaceLiftOpacity(backdropOpacity: -1)
            == UsageDockPopoverAppearance.minimumSurfaceLift)

        // Continuous: no step between the transparent end and the reference.
        var previous = UsageDockPopoverAppearance.surfaceLiftOpacity(backdropOpacity: 0)
        for step in 1...62 {
            let lift = UsageDockPopoverAppearance.surfaceLiftOpacity(
                backdropOpacity: Double(step) / 100
            )
            #expect(lift <= previous)
            #expect(previous - lift < 0.01)
            previous = lift
        }
    }

    @Test("Popover glass choices map to distinct native surface styles")
    func popoverSurfaceGlassStyleMapping() {
        #expect(UsageDockPopoverAppearance.surfaceGlassStyle(for: nil) == .regular)
        #expect(UsageDockPopoverAppearance.surfaceGlassStyle(for: .frosted) == .regular)
        #expect(UsageDockPopoverAppearance.surfaceGlassStyle(for: .clear) == .clear)
    }

    @Test("Both glass styles share high-contrast light roles")
    func adaptivePopupForegroundMapping() {
        for role in [
            UsageDockForegroundRole.primary,
            UsageDockForegroundRole.secondary,
            UsageDockForegroundRole.muted
        ] {
            #expect(colorsMatch(
                UsageDockPopoverAppearance.foregroundColor(
                    role,
                    glassStyle: .frosted
                ),
                UsageDockPopoverAppearance.foregroundColor(
                    role,
                    glassStyle: .clear
                )
            ))
        }
        #expect(
            UsageDockPopoverAppearance.glassShadowOpacity(
                .primary,
                glassStyle: .frosted
            ) > 0
        )
    }

    @Test("Clear glass uses protected light foregrounds on dark desktops")
    func clearGlassForegroundContrast() {
        let background = Color(hex: 0x19152D)
        let primary = UsageDockPopoverAppearance.foregroundColor(
            .primary,
            glassStyle: .clear
        )
        let secondary = UsageDockPopoverAppearance.foregroundColor(
            .secondary,
            glassStyle: .clear
        )
        let muted = UsageDockPopoverAppearance.foregroundColor(
            .muted,
            glassStyle: .clear
        )

        #expect(contrast(primary, background) >= 4.5)
        #expect(contrast(secondary, background) >= 4.5)
        #expect(contrast(muted, background) >= 4.5)
        #expect(luminance(primary) > luminance(secondary))
        #expect(luminance(secondary) > luminance(muted))
        #expect(
            UsageDockPopoverAppearance.glassShadowOpacity(.primary, glassStyle: .clear)
                < UsageDockPopoverAppearance.glassShadowOpacity(.muted, glassStyle: .clear)
        )
    }
}
