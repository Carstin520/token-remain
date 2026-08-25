import SwiftUI

/// The Dashboard background layers, ordered from the window ground up.
///
/// Only *background* roles live here. Text, provider identity and semantic
/// status keep their fixed values in `DashboardTheme`: the lightness preference
/// moves the ground the content sits on, never the content.
enum DashboardSurfaceRole: CaseIterable, Sendable {
    case canvas
    case surface
    case surface2
    case surface3
    case border
    case track

    /// The shipped dark value this role starts from at lightness 0.
    var baseHex: UInt {
        switch self {
        case .canvas: return DashboardTheme.canvasHex
        case .surface: return DashboardTheme.surfaceHex
        case .surface2: return DashboardTheme.surface2Hex
        case .surface3: return DashboardTheme.surface3Hex
        case .border: return DashboardTheme.borderHex
        case .track: return DashboardTheme.trackHex
        }
    }
}

/// Pure math behind the Dashboard's "background lightness" preference.
///
/// Every background layer travels the *same fraction* of the distance toward one
/// cool neutral, so the stack keeps its order (canvas < surface < surface2 <
/// surface3) and its border stays the lightest line on the card at every
/// position of the slider.
enum DashboardSurfaceLightening {
    /// Where the surfaces are heading: a hue-neutral, slightly blue-leaning grey
    /// (≈213°, ≈10% saturation). Deliberately *not* the brand violet — violet
    /// and cyan stay identity colors, they never become a background wash.
    static let neutralTargetHex: UInt = 0x8A9099

    /// Slider 1.0 spends only this much of the trip to the neutral.
    ///
    /// The cap is a readability budget, not a taste call. At 0.25 the lightest
    /// layer (`surface3`) reaches ≈#3C4046, where `secondaryText` still clears
    /// 4.5:1 and `mutedText` holds ≈3:1 against the canvas — so the fix for
    /// "the black is too deep" never turns into "the small text disappeared".
    /// Going further is what breaks the tertiary tier, which is why the range is
    /// narrowed here instead of by re-tinting the text colors.
    static let maximumBlend = 0.25

    /// User-facing preference range. 0 = exactly what shipped before.
    static let lightnessRange = 0.0...1.0

    static func clampedLightness(_ lightness: Double) -> Double {
        guard lightness.isFinite else { return lightnessRange.lowerBound }
        return min(max(lightness, lightnessRange.lowerBound), lightnessRange.upperBound)
    }

    /// How far a surface actually travels for a given slider position.
    static func blend(forLightness lightness: Double) -> Double {
        clampedLightness(lightness) * maximumBlend
    }

    static func components(ofHex hex: UInt) -> (red: Double, green: Double, blue: Double) {
        (
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Linear interpolation toward `neutralTargetHex`. Monotonic in `lightness`
    /// and applied identically to every role, which is what preserves the layer
    /// order.
    static func lightenedComponents(
        _ hex: UInt,
        lightness: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let base = components(ofHex: hex)
        let amount = blend(forLightness: lightness)
        guard amount > 0 else { return base }
        let target = components(ofHex: neutralTargetHex)
        return (
            red: base.red + (target.red - base.red) * amount,
            green: base.green + (target.green - base.green) * amount,
            blue: base.blue + (target.blue - base.blue) * amount
        )
    }

    static func color(_ hex: UInt, lightness: Double) -> Color {
        let rgb = lightenedComponents(hex, lightness: lightness)
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    // MARK: - Contrast (used by the design tests to police the cap above)

    static func relativeLuminance(
        of rgb: (red: Double, green: Double, blue: Double)
    ) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red)
            + 0.7152 * linear(rgb.green)
            + 0.0722 * linear(rgb.blue)
    }

    static func contrastRatio(
        _ first: (red: Double, green: Double, blue: Double),
        _ second: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let a = relativeLuminance(of: first)
        let b = relativeLuminance(of: second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// WCAG contrast of a fixed foreground hex against a lightened surface.
    static func contrastRatio(
        foregroundHex: UInt,
        surfaceHex: UInt,
        lightness: Double
    ) -> Double {
        contrastRatio(
            components(ofHex: foregroundHex),
            lightenedComponents(surfaceHex, lightness: lightness)
        )
    }
}

/// The resolved background layer set for one rendering context.
///
/// `dark` is the shipped palette and the environment default, so any surface
/// that never opts in — the menu-bar popup above all, which owns its own
/// opacity slider — is byte-for-byte unchanged.
struct DashboardSurfacePalette: Equatable, Sendable {
    let lightness: Double

    static let dark = DashboardSurfacePalette(lightness: 0)

    init(lightness: Double) {
        self.lightness = DashboardSurfaceLightening.clampedLightness(lightness)
    }

    func color(for role: DashboardSurfaceRole) -> Color {
        DashboardSurfaceLightening.color(role.baseHex, lightness: lightness)
    }

    var canvas: Color { color(for: .canvas) }
    var surface: Color { color(for: .surface) }
    var surface2: Color { color(for: .surface2) }
    var surface3: Color { color(for: .surface3) }
    var border: Color { color(for: .border) }
    var track: Color { color(for: .track) }
}

/// A background token that resolves against the environment at draw time.
///
/// Using a `ShapeStyle` rather than a plain `Color` is what keeps this a
/// Dashboard-only preference without threading a value through every view: the
/// same token renders lightened inside the Dashboard and stays dark in the
/// popup, because resolution reads whatever palette that subtree carries.
struct DashboardSurfaceStyle: ShapeStyle {
    let role: DashboardSurfaceRole

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.dashboardSurfaces.color(for: role)
    }
}

/// Preference-aware counterparts of the `DashboardTheme` background tokens.
/// Use these for anything that paints a Dashboard background, border or track;
/// keep `DashboardTheme` for ink, identity and status colors.
enum DashboardSurface {
    static let canvas = DashboardSurfaceStyle(role: .canvas)
    static let surface = DashboardSurfaceStyle(role: .surface)
    static let surface2 = DashboardSurfaceStyle(role: .surface2)
    static let surface3 = DashboardSurfaceStyle(role: .surface3)
    static let border = DashboardSurfaceStyle(role: .border)
    static let track = DashboardSurfaceStyle(role: .track)
}

private struct DashboardSurfacePaletteKey: EnvironmentKey {
    static let defaultValue = DashboardSurfacePalette.dark
}

extension EnvironmentValues {
    /// The background palette for this subtree. Defaults to the fixed dark set.
    var dashboardSurfaces: DashboardSurfacePalette {
        get { self[DashboardSurfacePaletteKey.self] }
        set { self[DashboardSurfacePaletteKey.self] = newValue }
    }
}

extension View {
    /// Applies the Dashboard's background-lightness preference to a subtree.
    func dashboardSurfaces(lightness: Double) -> some View {
        environment(\.dashboardSurfaces, DashboardSurfacePalette(lightness: lightness))
    }
}
