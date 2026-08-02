import SwiftUI

/// Semantic dark tokens for content and pre-macOS 26 surface fallbacks.
///
/// These are the confirmed "TokenRemain" mobile palette (`TRTheme`): a
/// pixel-tech, low-contrast robot visual language on an ink ground.
///
/// Three color roles are kept deliberately separate:
/// - **Product accents** use violet for navigation and selection;
///   cyan is reserved for informational emphasis such as quota/Token news and
///   the robot's signal details.
/// - **Provider identity** keeps each app's assigned hue in quota meters,
///   comparison charts and official provider glyphs. Saturation, luminance and
///   opacity may adapt to context; the identifying hue must not be reassigned.
/// - **Semantic status** uses conventional green / amber / red so a warning
///   looks like a warning — always paired with a glyph + text label, never
///   color alone.
///
/// macOS 26 surfaces use system Liquid Glass and materials; these colors retain
/// the product identity and keep macOS 14/15 visually compatible.
enum DashboardTheme {
    // Reference brand lockup: near-black ground, cool-white "Token", and
    // violet "Remain". Keep these semantic so the wordmark and product chrome
    // stay synchronized without affecting provider or status colors.
    static let brandCanvas = Color(hex: 0x0D0E10)
    static let brandToken = Color(hex: 0xF2F3F5)
    static let brandRemain = Color(hex: 0x9B8AFB)

    // Surfaces — restrained, hue-neutral charcoal. Large fields must not
    // compete with provider identity or semantic status colors.
    static let canvas = brandCanvas              // window / popover background
    static let surface = Color(hex: 0x121316)    // primary card
    static let surface2 = Color(hex: 0x1A1B1F)   // secondary chip / inset
    static let surface3 = Color(hex: 0x23252A)   // raised element
    static let border = Color(hex: 0x32353C)     // 1px card borders, pixel ticks
    static let track = Color(hex: 0x272A30)      // empty segment / progress track

    // Text (Color 3)
    static let text = brandToken
    static let secondaryText = Color(hex: 0xA7ABB4)
    static let mutedText = Color(hex: 0x6F7580)

    // Color 1 — violet: robot and primary product accent
    static let violet = brandRemain
    static let violetDim = Color(hex: 0x6357B8)

    // Cyan is the informational highlight and the robot's signal detail. It is
    // intentionally distinct from violet interaction chrome and amber warnings.
    static let cyan = Color(hex: 0x3ECFE0)
    static let cyanDim = Color(hex: 0x2B8FA0)

    // Provider theme palette. Red is deliberately absent: it is reserved for
    // critically low remaining quota. These are quieter, contrast-matched
    // expressions of each app's identity hue; assignments remain stable across
    // quota meters and comparisons and are paired with a glyph or text label.
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
    /// starburst / terminal-prompt marks in `BrandIcon`). Glyphs can carry the
    /// saturated brand expression while larger meters use the quieter,
    /// contrast-matched provider accents above.
    static let claudeBrand = Color(hex: 0xD97757)   // Anthropic coral (official, full saturation)
    static let codexBrand = Color(hex: 0x3578F6)    // Codex deep blue (official, full saturation)

    // MARK: - Brand identity

    static let claude = claudeAccent
    static let codex = codexAccent
    /// Primary brand accent.
    static let purple = violet
    /// Links share the same violet as TokenRemain selection chrome.
    static let link = violet

    // MARK: - Semantic content emphasis

    /// Product information that deserves attention without implying danger:
    /// quota changes, token pricing, reset announcements and hot-story rank.
    static let information = cyan

    /// Single source of truth for AI-feed priority chrome across Dashboard,
    /// Trending and the menu-bar popover.
    static func feedAccent(for priority: AIFeedPriority) -> Color {
        switch priority {
        case .tokenReset: return information
        case .majorUpdate: return violetDim
        case .normal: return mutedText
        }
    }

    // MARK: - Semantic status (conventional green / amber / red)
    // Always paired with a glyph + text label at the call site — never color alone.

    /// good / on-track / success.
    static let success = Color(hex: 0x57D19A)
    /// medium / warning (paired with a "!" glyph at the call site).
    static let warning = Color(hex: 0xFFB554)
    /// high / danger (paired with a "‼" glyph at the call site).
    static let danger = Color(hex: 0xFF6B6B)

    /// The stable theme accent for a provider's quota meter and comparisons.
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
    /// At 10% and above, the provider's stable theme color is restored.
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
