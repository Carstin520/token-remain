import SwiftUI

/// Typography tokens synced to the mobile design system
/// shared by the desktop dashboard and menu-bar surfaces.
///
/// Rules:
/// - Body text and labels use **system SF**. There is no third-party pixel
///   font — the pixel feel comes from chrome, not glyphs.
/// - **Every numeral** (percentages, token counts, costs, countdowns, clock
///   times) renders in **SF Pro with tabular digits** (`.monospacedDigit()`),
///   so columns still align while values read like body text. Heavy weights
///   are capped at semibold: bold SF Mono at KPI sizes was hard to read.
/// - SF Mono remains only for chrome that is meant to look technical: the
///   uppercase meta badges and the brand wordmark.
/// - A mixed line (e.g. `剩余 46%`) is fine — CJK characters use the system
///   CJK face either way.
extension DashboardTheme {
    enum Typo {
        /// SF Mono at an explicit size — badges and the wordmark only.
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// SF Pro for numeral-bearing text; pair with `.monospacedDigit()`.
        static func numeric(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: readable(weight))
        }

        /// Bold and heavier numerals crowd at small sizes; semibold keeps the
        /// emphasis without the smear.
        static func readable(_ weight: Font.Weight) -> Font.Weight {
            switch weight {
            case .bold, .heavy, .black: .semibold
            default: weight
            }
        }

        /// System SF for body/labels/captions.
        static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        /// Uppercase monospaced meta badge; apply `.tracking()` at the call site.
        static func badge(_ size: CGFloat = 9) -> Font { mono(size, .bold) }

        /// The monospaced brand wordmark face ("TokenRemain").
        static func wordmark(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
            mono(size, weight)
        }
    }
}

extension View {
    /// Numeral styling: SF Pro + tabular digits. Use for any `Text` that
    /// carries numbers (%, token counts, costs, countdowns, clock times). Safe on
    /// mixed number+CJK lines — Chinese falls back to the system CJK face.
    func numericFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(DashboardTheme.Typo.numeric(size, weight)).monospacedDigit()
    }

    /// The monospaced brand wordmark face.
    func wordmarkFont(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        font(DashboardTheme.Typo.wordmark(size, weight))
    }
}

enum TokenRemainWordmarkStyle {
    case brand
    case monochrome
}

/// The desktop wordmark remains native text so it scales crisply and reads as
/// one accessible heading instead of a decorative raster asset. The Dashboard
/// may use the two-tone brand lockup; compact menu-bar chrome uses one neutral
/// color so branding does not introduce a second decorative accent.
struct TokenRemainWordmark: View {
    var size: CGFloat
    var weight: Font.Weight = .bold
    var style: TokenRemainWordmarkStyle = .brand

    var body: some View {
        HStack(spacing: 0) {
            Text("Token")
                .usageDockAdaptiveForeground(.primary)
            if case .monochrome = style {
                Text("Remain")
                    .usageDockAdaptiveForeground(.primary)
            } else {
                Text("Remain")
                    .foregroundStyle(DashboardTheme.brandRemain)
            }
        }
        .wordmarkFont(size, weight)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TokenRemain")
    }
}
