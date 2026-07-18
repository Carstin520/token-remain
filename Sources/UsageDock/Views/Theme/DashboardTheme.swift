import SwiftUI

/// Semantic dark design tokens for the V2 UsageDock surfaces.
///
/// Values mirror the approved prototype's CSS custom properties so the popover
/// and Dashboard read as one restrained, high-density dark system regardless of
/// the host system appearance. All UsageDock SwiftUI roots force `.dark`, so
/// these tokens are the single source of truth for color and never rely on the
/// system-provided semantic colors.
enum DashboardTheme {
    // Surfaces
    static let canvas = Color(hex: 0x090D14)     // window / popover background
    static let surface = Color(hex: 0x121823)    // primary card
    static let surface2 = Color(hex: 0x1A2230)   // secondary chip / inset
    static let surface3 = Color(hex: 0x202B3B)   // raised element
    static let border = Color(hex: 0x2C3748)
    static let track = Color(hex: 0x242E3D)      // progress track

    // Text
    static let text = Color(hex: 0xF4F6F9)
    static let secondaryText = Color(hex: 0xA0A8B7)
    static let mutedText = Color(hex: 0x6F7989)

    // Brand + status
    static let claude = Color(hex: 0xD97757)
    static let codex = Color(hex: 0x4B9CFB)
    static let success = Color(hex: 0x57D19A)
    static let warning = Color(hex: 0xFFB554)
    static let danger = Color(hex: 0xFF6B6B)
    static let purple = Color(hex: 0x8B7CF6)
    static let link = Color(hex: 0x76B5FF)

    // Fills
    static let claudeFill = LinearGradient(
        colors: [Color(hex: 0xD97757), Color(hex: 0xF0A071)],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let codexFill = LinearGradient(
        colors: [Color(hex: 0x4B9CFB), Color(hex: 0x78B6FF)],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The accent gradient a provider's progress bars should use.
    static func fill(for provider: ProviderQuota.Provider) -> LinearGradient {
        provider == .claude ? claudeFill : codexFill
    }

    /// The flat accent color for a provider.
    static func accent(for provider: ProviderQuota.Provider) -> Color {
        provider == .claude ? claude : codex
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
