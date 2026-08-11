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
        #expect(UsageDockPopoverAppearance.surfaceTintOpacity(backdropOpacity: 0) == 0)
        #expect(UsageDockPopoverAppearance.surfaceTintOpacity(backdropOpacity: 1) == 1)
        #expect(UsageDockPopoverAppearance.surfaceTintOpacity(backdropOpacity: -1) == 0)
        #expect(UsageDockPopoverAppearance.surfaceTintOpacity(backdropOpacity: 2) == 1)
    }

    /// The popup's ink is a flat scrim, not a glass tint, and it never fully
    /// clears. macOS hit-tests borderless transparent windows per pixel, and
    /// `glassEffect` refraction lands outside the window's own backing store —
    /// a shell with no scrim had alpha ≈ 0, so clicks fell through to the
    /// desktop and the popup's outside-click monitor closed it on the user.
    @Test("The popup scrim never falls below the click-through threshold")
    func scrimFloorKeepsThePanelHittable() {
        // The measured pass-through threshold is ≈0.05; the floor keeps clear
        // margin over it for edge antialiasing and colour rounding.
        #expect(UsageDockPopoverAppearance.minimumScrimOpacity >= 0.10)
        for step in 0...100 {
            let scrim = UsageDockPopoverAppearance.scrimOpacity(
                backdropOpacity: Double(step) / 100
            )
            #expect(scrim >= UsageDockPopoverAppearance.minimumScrimOpacity)
        }
        // Out-of-range values are clamped, not passed through.
        #expect(
            UsageDockPopoverAppearance.scrimOpacity(backdropOpacity: -1)
                == UsageDockPopoverAppearance.minimumScrimOpacity
        )
        #expect(UsageDockPopoverAppearance.scrimOpacity(backdropOpacity: 2) == 1)
    }

    /// The slider has to *look* like it does something. Spent as a tint on
    /// `Glass.clear` it saturated — 66% and 30% were indistinguishable on
    /// screen. A flat colour layer scales linearly, so above the floor the
    /// scrim tracks the slider one-to-one.
    @Test("The popup opacity slider maps linearly onto the scrim above its floor")
    func scrimFollowsTheSliderLinearly() {
        let floor = UsageDockPopoverAppearance.minimumScrimOpacity
        for step in 0...100 {
            let value = Double(step) / 100
            guard value >= floor else { continue }
            #expect(
                abs(UsageDockPopoverAppearance.scrimOpacity(backdropOpacity: value) - value)
                    < 0.0001
            )
        }
        // Monotonic across the whole travel, and the shipped test positions are
        // far enough apart to read as three different popups.
        var previous = 0.0
        for step in 0...100 {
            let scrim = UsageDockPopoverAppearance.scrimOpacity(
                backdropOpacity: Double(step) / 100
            )
            #expect(scrim >= previous)
            previous = scrim
        }
        #expect(
            UsageDockPopoverAppearance.scrimOpacity(backdropOpacity: 0.5)
                - UsageDockPopoverAppearance.scrimOpacity(backdropOpacity: 0.1) >= 0.3
        )
        #expect(
            UsageDockPopoverAppearance.scrimOpacity(backdropOpacity: 0.9)
                - UsageDockPopoverAppearance.scrimOpacity(backdropOpacity: 0.5) >= 0.3
        )
    }

    /// The two popup controls own two different parts of the popup: the Glass
    /// style switch owns the material of the UI — card density included — and
    /// the opacity slider owns only the shell scrim. Card tint is therefore a
    /// per-style constant with no slider input at all.
    @Test("Card density belongs to the glass style, not the slider")
    func cardTintBelongsToTheStyle() {
        // Inside the band the redesign spec allows: light enough to see the
        // desktop through, heavy enough that the card is still a surface.
        #expect(UsageDockPopoverAppearance.clearSurfaceTintCoefficient >= 0.35)
        #expect(UsageDockPopoverAppearance.clearSurfaceTintCoefficient <= 0.5)

        // Clear cards are a fixed fraction of the frosted reference density.
        let frosted = UsageDockPopoverAppearance.cardTintOpacity(glassStyle: .frosted)
        let clear = UsageDockPopoverAppearance.cardTintOpacity(glassStyle: .clear)
        #expect(frosted == UsageDockPopoverAppearance.referenceBackdropOpacity)
        #expect(
            abs(
                clear - frosted * UsageDockPopoverAppearance.clearSurfaceTintCoefficient
            ) < 0.0001
        )
        #expect(clear < frosted)
        // The Dashboard (nil style) keeps the frosted reference density.
        #expect(UsageDockPopoverAppearance.cardTintOpacity(glassStyle: nil) == frosted)
        // Both are real surfaces: never fully transparent, never opaque.
        #expect(clear > 0.1)
        #expect(frosted < 1)
    }

    /// Popup cards have to answer the pointer. `Glass.interactive()` is applied
    /// as well, but its response is defined against the untinted native
    /// material, so the explicit lift is what guarantees the state change is
    /// visible in both glass styles.
    @Test("Popup cards carry a visible but non-selecting pointer highlight")
    func surfaceHighlightLift() {
        // Both styles must answer the pointer; nil (the Dashboard window) never
        // reaches this — its cards are not interactive.
        for style in [PopoverGlassStyle.clear, .frosted] {
            let lift = UsageDockPopoverAppearance.surfaceHighlightLift(glassStyle: style)
            #expect(lift > 0)
            // Far below an opaque wash in either style. Clear composites the
            // overlay at its stated value, so its ceiling is the tight one.
            #expect(lift < 0.5)
        }
        // Clear stays inside the design band directly; Frosted's glass transmits
        // roughly an eighth of an overlay above it, so its nominal value has to
        // be the larger of the two to render as the same lift.
        #expect(UsageDockPopoverAppearance.clearSurfaceHighlightLift >= 0.04)
        #expect(UsageDockPopoverAppearance.clearSurfaceHighlightLift <= 0.06)
        #expect(
            UsageDockPopoverAppearance.frostedSurfaceHighlightLift
                > UsageDockPopoverAppearance.clearSurfaceHighlightLift
        )
        // A hover must not out-weigh the card's own resting presence, or the
        // highlight reads as a selected state rather than a pointer response.
        #expect(
            UsageDockPopoverAppearance.clearSurfaceHighlightLift
                < UsageDockPopoverAppearance.cardTintOpacity(glassStyle: .clear)
        )
        // Fast enough to feel attached to the pointer.
        #expect(UsageDockPopoverAppearance.surfaceHighlightTransitionDuration <= 0.2)
        #expect(UsageDockPopoverAppearance.surfaceHighlightTransitionDuration > 0)
    }

    @Test("Frosted retains its pre-redesign border curve")
    func frostedBorderCurve() {
        #expect(UsageDockPopoverAppearance.borderOpacity(backdropOpacity: -1) == 0.85)
        #expect(UsageDockPopoverAppearance.borderOpacity(backdropOpacity: 0) == 0.85)
        #expect(abs(UsageDockPopoverAppearance.borderOpacity(backdropOpacity: 1) - 0.45) < 0.0001)
        #expect(abs(UsageDockPopoverAppearance.borderOpacity(backdropOpacity: 2) - 0.45) < 0.0001)
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
