import SwiftUI

/// Semantic dark tokens for content and pre-macOS 26 surface fallbacks.
///
/// These are the confirmed "Token Remain" mobile palette (`TRTheme`): a
/// pixel-tech, low-contrast robot visual language on an ink ground.
///
/// Two color roles are kept deliberately separate:
/// - **Brand identity / accents** use violet + cyan (Claude, Codex, links,
///   selection, meta badges, segment bars, pixel chrome).
/// - **Semantic status** uses conventional green / amber / red so a warning
///   looks like a warning — always paired with a glyph + text label, never
///   color alone.
///
/// macOS 26 surfaces use system Liquid Glass and materials; these colors retain
/// the product identity and keep macOS 14/15 visually compatible.
enum DashboardTheme {
    // Surfaces
    static let canvas = Color(hex: 0x070B12)     // window / popover background
    static let surface = Color(hex: 0x0D1420)    // primary card
    static let surface2 = Color(hex: 0x141D2C)   // secondary chip / inset
    static let surface3 = Color(hex: 0x1B2536)   // raised element
    static let border = Color(hex: 0x223044)     // 1px card borders, pixel ticks
    static let track = Color(hex: 0x1B2536)      // empty segment / progress track

    // Text (Color 3)
    static let text = Color(hex: 0xE9EDF5)
    static let secondaryText = Color(hex: 0x8B97AB)
    static let mutedText = Color(hex: 0x55617A)

    // Color 1 — violet: robot, Claude accent, primary accent, LOW risk
    static let violet = Color(hex: 0x8F7BF2)
    static let violetDim = Color(hex: 0x5B4FB0)

    // Color 2 — cyan: Codex accent, countdowns, confirmations / on-track
    static let cyan = Color(hex: 0x3ECFE0)
    static let cyanDim = Color(hex: 0x2B8FA0)

    // Provider-slot extensions (slots 3–5) — reserved identity colors for future
    // usage sources. Values are CVD-validated on the dark surface; do not alter.
    static let indigo = Color(hex: 0x2F5FD0)
    static let indigoDim = Color(hex: 0x24479C)
    static let magenta = Color(hex: 0xD95FB8)
    static let magentaDim = Color(hex: 0xA2478A)
    static let olive = Color(hex: 0x7DA342)
    static let oliveDim = Color(hex: 0x5D7A31)

    // MARK: - Provider color slots (reserved)

    /// Ordered identity palette for usage-source providers, CVD-validated on the
    /// dark `surface`. Assignment rules — these are load-bearing, not stylistic:
    ///
    /// - A newly onboarded provider takes the **next free slot in order**
    ///   (slot 1 → Claude, slot 2 → Codex are already spoken for).
    /// - A slot's color follows the entity **permanently**: once a provider owns
    ///   a slot it keeps it, and slots are **never re-assigned** when the visible
    ///   subset of providers changes (filtering, hiding, or reordering must not
    ///   shuffle colors).
    /// - Semantic green / amber / red are **never** used as a provider color —
    ///   those stay reserved for status.
    /// - A provider color must **always be paired with a glyph + text label**
    ///   (icon + name); color alone never identifies a provider.
    ///
    /// Slot order: 1 violet (Claude), 2 cyan (Codex), 3 indigo, 4 magenta,
    /// 5 olive. `providerSlotsDim` holds the matching muted variants at the same
    /// indices (resting segments / strokes).
    static let providerSlots: [Color] = [violet, cyan, indigo, magenta, olive]

    /// Muted variant for each entry in `providerSlots`, index-aligned.
    static let providerSlotsDim: [Color] = [violetDim, cyanDim, indigoDim, magentaDim, oliveDim]

    // MARK: - Official provider brand marks (glyph tint only)

    /// Official brand colors used ONLY for the provider identity glyph (the
    /// starburst / terminal-prompt marks in `BrandIcon`). These are deliberately
    /// separate from the accent system: quota bars, selection, and pixel chrome
    /// stay violet/cyan — only the logo glyph carries the vendor's own color.
    static let claudeBrand = Color(hex: 0xD97757)   // Anthropic coral
    static let codexBrand = Color(hex: 0x4B9CFB)    // Codex blue

    // MARK: - Brand identity (violet / cyan)

    /// Provider identity — the confirmed mobile brand: Claude = violet, Codex = cyan.
    static let claude = violet
    static let codex = cyan
    /// Primary brand accent.
    static let purple = violet
    /// Links use the cyan accent.
    static let link = cyan

    // MARK: - Semantic status (conventional green / amber / red)
    // Always paired with a glyph + text label at the call site — never color alone.

    /// good / on-track / success.
    static let success = Color(hex: 0x57D19A)
    /// medium / warning (paired with a "!" glyph at the call site).
    static let warning = Color(hex: 0xFFB554)
    /// high / danger (paired with a "‼" glyph at the call site).
    static let danger = Color(hex: 0xFF6B6B)

    /// The flat accent color for a provider's segment bars and glyphs.
    static func accent(for provider: ProviderQuota.Provider) -> Color {
        provider == .claude ? violet : cyan
    }

    /// Risk tint uses conventional semantic status colors: LOW = green,
    /// MEDIUM = amber, HIGH = red (rendered as a filled white-on-red badge at
    /// the call site), UNKNOWN = secondary text. This is the single source of
    /// truth for `RiskLevel.tint`.
    static func riskAccent(for risk: RiskLevel) -> Color {
        switch risk {
        case .low: return success
        case .medium: return warning
        case .high: return danger
        case .unknown: return secondaryText
        }
    }
}

extension Color {
    /// Builds an opaque color from a `0xRRGGBB` literal so the tokens read like
    /// the prototype's hex values.
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
