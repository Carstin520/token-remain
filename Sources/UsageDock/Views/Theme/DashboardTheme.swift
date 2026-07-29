import SwiftUI

/// Semantic dark tokens for content and pre-macOS 26 surface fallbacks.
///
/// These are the confirmed "TokenRemain" mobile palette (`TRTheme`): a
/// pixel-tech, low-contrast robot visual language on an ink ground.
///
/// Two color roles are kept deliberately separate:
/// - **Product accents** use violet + cyan (links, selection, meta badges,
///   pixel chrome).
/// - **Provider identity** uses a distinct categorical palette for quota bars.
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

    // Color 1 — violet: robot and primary product accent
    static let violet = Color(hex: 0x8F7BF2)
    static let violetDim = Color(hex: 0x5B4FB0)

    // Color 2 — cyan: links, countdowns and product chrome
    static let cyan = Color(hex: 0x3ECFE0)
    static let cyanDim = Color(hex: 0x2B8FA0)

    // Provider quota palette. Red is deliberately absent: it is reserved for
    // a critically low remaining quota. Every entry sits in the same muted
    // tonal band (saturation ~35-45%, similar lightness) so hue alone carries
    // identity and adjacent cards read as one calm system instead of a mix of
    // fluorescent brand colors.
    static let claudeAccent = Color(hex: 0xBF8471)      // muted terracotta
    static let codexAccent = Color(hex: 0x6687C5)       // muted steel blue
    static let cursorAccent = Color(hex: 0x9684CD)      // muted violet
    static let copilotAccent = Color(hex: 0x64ABB4)     // muted cyan
    static let devinAccent = Color(hex: 0x5AAA9F)       // muted teal
    static let grokAccent = Color(hex: 0xC1AD5C)        // muted gold
    static let openrouterAccent = Color(hex: 0x94A3B8)  // slate
    static let antigravityAccent = Color(hex: 0x7499C3) // muted sky blue
    static let opencodeAccent = Color(hex: 0x63AB91)    // muted green
    static let zaiAccent = Color(hex: 0x9CB766)         // muted lime

    // MARK: - Provider color slots (reserved)

    /// Ordered identity palette for usage-source providers, CVD-validated on the
    /// dark `surface`. Assignment rules — these are load-bearing, not stylistic:
    ///
    /// - A slot's color follows the entity **permanently**: once a provider owns
    ///   a slot it keeps it, and slots are **never re-assigned** when the visible
    ///   subset of providers changes (filtering, hiding, or reordering must not
    ///   shuffle colors).
    /// - Semantic red is **never** used as a normal provider color — it stays
    ///   reserved for critically low quota.
    /// - A provider color must **always be paired with a glyph + text label**
    ///   (icon + name); color alone never identifies a provider.
    ///
    /// Historical chart slots remain stable for cached Claude/Codex series.
    static let providerSlots: [Color] = [
        claudeAccent, codexAccent, cursorAccent, grokAccent, zaiAccent
    ]

    /// Muted variant for each entry in `providerSlots`, index-aligned.
    static let providerSlotsDim: [Color] = [
        Color(hex: 0x956758), Color(hex: 0x50699A), Color(hex: 0x7567A0),
        Color(hex: 0x978748), Color(hex: 0x7A8F50)
    ]

    // MARK: - Official provider brand marks (glyph tint only)

    /// Official brand colors used ONLY for the provider identity glyph (the
    /// starburst / terminal-prompt marks in `BrandIcon`). These are deliberately
    /// named separately from the categorical quota palette even when the current
    /// Claude/Codex values intentionally match their meter identity colors.
    static let claudeBrand = Color(hex: 0xD97757)   // Anthropic coral (official, full saturation)
    static let codexBrand = Color(hex: 0x3578F6)    // Codex deep blue (official, full saturation)

    // MARK: - Brand identity

    static let claude = claudeAccent
    static let codex = codexAccent
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
        switch provider {
        case .claude: return claudeAccent
        case .codex: return codexAccent
        case .cursor: return cursorAccent
        case .grok: return grokAccent
        case .zai: return zaiAccent
        case .copilot: return copilotAccent
        case .devin: return devinAccent
        case .windsurf: return Color(hex: 0x70AFA6)
        case .openrouter: return openrouterAccent
        case .antigravity: return antigravityAccent
        case .opencode: return opencodeAccent
        case .deepseek: return Color(hex: 0x7382CA)     // muted indigo
        case .kimi: return Color(hex: 0x86B5C6)          // muted ice cyan
        case .minimax: return Color(hex: 0xC06E7E)       // muted rose
        case .mimo: return Color(hex: 0xC689A9)          // muted pink
        case .qoder: return Color(hex: 0xA07FB0)         // muted mauve
        case .kiro: return Color(hex: 0xA292C7)          // muted lavender
        case .volcengine: return Color(hex: 0x6BA3C4)    // muted volcano sky
        case .ollama: return Color(hex: 0xCBD5E1)        // light slate
        }
    }

    /// Quota meters reserve red for the same critical threshold as `RiskLevel`.
    /// At 10% and above, the provider's stable identity color is restored.
    static func quotaAccent(
        for provider: ProviderQuota.Provider,
        remainingPercent: Double
    ) -> Color {
        remainingPercent < 10 ? danger : accent(for: provider)
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
