import SwiftUI

/// Low-contrast, dark-only palette. The only chromatic accents in the entire
/// product are Robot Violet, Robot Indigo and Robot Cyan; everything else is a
/// neutral (near-black navy, graphite, cool gray, soft off-white). There are no
/// orange / green / yellow / red semantic colours anywhere — risk is expressed by
/// accent + text + glyph, never hue alone.
public enum TRTheme {
    // Neutrals
    /// Near-black navy canvas.
    public static let ink = Color(hex: 0x070B12)
    /// Graphite card surface.
    public static let surface = Color(hex: 0x0D1420)
    /// Graphite inset / chip.
    public static let surface2 = Color(hex: 0x141D2C)
    /// 1px card borders and pixel corner ticks.
    public static let border = Color(hex: 0x223044)
    /// Empty bar segments.
    public static let track = Color(hex: 0x1B2536)
    /// Soft off-white — primary text and values.
    public static let text = Color(hex: 0xE9EDF5)
    /// Cool gray — secondary text.
    public static let textDim = Color(hex: 0x8B97AB)
    /// Cool gray — captions and disabled ornament only, never value-bearing.
    public static let textMute = Color(hex: 0x55617A)

    // The three chromatic accents
    /// Robot Violet — the robot, Claude, primary accents, LOW badge.
    public static let violet = Color(hex: 0x8357F5)
    public static let violetDim = Color(hex: 0x5A3EA8)
    /// Robot Indigo — system actions (refresh control, CTA, links).
    public static let indigo = Color(hex: 0x4D5FE8)
    public static let indigoDim = Color(hex: 0x35429E)
    /// Robot Cyan — Codex, countdowns, confirmations.
    public static let cyan = Color(hex: 0x00CDE8)
    public static let cyanDim = Color(hex: 0x0A7C8C)

    // MARK: - Semantic status (palette.md v1.1)

    /// Conventional status colours from `design/palette.md`. These express *good /
    /// tight / bad* only, always paired with a glyph (✓ / ! / ‼) and a text label —
    /// never hue alone. They are a separate category from the brand accents above and
    /// are never used for meters, series colours or selection.
    public static let success = Color(hex: 0x57D19A)
    public static let warning = Color(hex: 0xFFB554)
    public static let danger = Color(hex: 0xFF6B6B)

    // MARK: - Provider brand (logo glyphs only, palette.md rule 0)

    /// Official provider brand colours, used **only** for the identity glyph — never
    /// for meters or chart series (those stay violet / cyan). Claude = starburst
    /// coral; Codex = terminal-prompt blue.
    public static let claudeBrand = Color(hex: 0xD97757)
    public static let codexBrand = Color(hex: 0x4B9CFB)

    /// Increase-Contrast substitutions (§4).
    public static let borderHighContrast = Color(hex: 0x3A4A66)

    public static func accent(for provider: ProviderQuota.Provider) -> Color {
        switch provider {
        case .claude: return violet
        case .codex: return cyan
        }
    }

    public static func accentDim(for provider: ProviderQuota.Provider) -> Color {
        switch provider {
        case .claude: return violetDim
        case .codex: return cyanDim
        }
    }

    /// Risk never maps to red/green. LOW is violet, MEDIUM is cyan, HIGH is
    /// off-white text on a violet field — and every badge also carries a glyph.
    public static func riskAccent(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return violet
        case .medium: return cyan
        case .high: return violet
        case .unknown: return textMute
        }
    }

    public static func riskIsFilled(_ risk: RiskLevel) -> Bool { risk == .high }

    /// Semantic risk colour (palette.md v1.1): low → green, medium → amber,
    /// high → red, unknown → muted. Always rendered with the level's glyph + label.
    public static func riskSemantic(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return success
        case .medium: return warning
        case .high: return danger
        case .unknown: return textMute
        }
    }

    /// Official brand colour for a provider's identity glyph (logo only).
    public static func brandColor(for provider: ProviderQuota.Provider) -> Color {
        switch provider {
        case .claude: return claudeBrand
        case .codex: return codexBrand
        }
    }
}

// MARK: - Contrast math (asserted in TRThemeContrastTests)

public struct WCAG {
    /// sRGB relative luminance.
    public static func luminance(hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let value = Double(raw) / 255.0
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    public static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(hex: a)
        let lb = luminance(hex: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// Raw hex values kept alongside the `Color` tokens so contrast can be asserted
/// as pure math (no snapshotting, no rendering).
public enum TRThemeHex {
    public static let ink: UInt32 = 0x070B12
    public static let surface: UInt32 = 0x0D1420
    public static let surface2: UInt32 = 0x141D2C
    public static let border: UInt32 = 0x223044
    public static let track: UInt32 = 0x1B2536
    public static let text: UInt32 = 0xE9EDF5
    public static let textDim: UInt32 = 0x8B97AB
    public static let textMute: UInt32 = 0x55617A
    public static let violet: UInt32 = 0x8357F5
    public static let violetDim: UInt32 = 0x5A3EA8
    public static let indigo: UInt32 = 0x4D5FE8
    public static let indigoDim: UInt32 = 0x35429E
    public static let cyan: UInt32 = 0x00CDE8
    public static let cyanDim: UInt32 = 0x0A7C8C
    public static let success: UInt32 = 0x57D19A
    public static let warning: UInt32 = 0xFFB554
    public static let danger: UInt32 = 0xFF6B6B
    public static let claudeBrand: UInt32 = 0xD97757
    public static let codexBrand: UInt32 = 0x4B9CFB
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
