import AppKit
import SwiftUI
import Testing
@testable import UsageDock

/// WCAG contrast guarantees for the pixel-tech "Token Remain" palette. Value-
/// bearing text (`text`, `secondaryText`) must stay legible on `surface`; the
/// three brand accents must also clear the 4.5:1 body-text threshold so a
/// remaining-% or badge rendered in an accent stays readable.
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

    @Test("Both brand accents clear WCAG AA on surface")
    func accentContrast() {
        #expect(contrast(DashboardTheme.violet, DashboardTheme.surface) >= 4.5)
        #expect(contrast(DashboardTheme.cyan, DashboardTheme.surface) >= 4.5)
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

    /// Filled badges (e.g. HIGH risk) print ink text on the status field — white
    /// fails on the red field (≈2.8:1), so the palette mandates ink. Verify ink
    /// clears WCAG AA text contrast on the warning and danger fills.
    @Test("Ink text on filled status fields clears WCAG AA")
    func inkOnFilledContrast() {
        #expect(contrast(DashboardTheme.canvas, DashboardTheme.danger) >= 4.5)
        #expect(contrast(DashboardTheme.canvas, DashboardTheme.warning) >= 4.5)
    }
}
