import SwiftUI

/// Typography tokens synced to the mobile design system
/// (`apple/FABLE-FUNCTIONAL-SPEC.md` §3.2).
///
/// Rules:
/// - Body text and labels use **system SF**. There is no third-party pixel
///   font — the pixel feel comes from chrome, not glyphs.
/// - **Every numeral** (percentages, token counts, costs, countdowns, clock
///   times) renders in **SF Mono** with tabular digits: `.system(design:
///   .monospaced)` + `.monospacedDigit()`.
/// - SF Mono has no CJK glyphs, so the monospaced face is applied only to
///   numeric `Text` views. zh-Hans labels stay system SF; a mixed line
///   (e.g. `剩余 46%`) is fine — the digits render SF Mono and the Chinese
///   characters fall back to the system CJK face.
extension DashboardTheme {
    enum Typo {
        /// SF Mono at an explicit size — the face for all numeral-bearing text.
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
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
    /// Numeral styling: SF Mono face + tabular digits. Use for any `Text` that
    /// carries numbers (%, token counts, costs, countdowns, clock times). Safe on
    /// mixed number+CJK lines — Chinese falls back to the system CJK face.
    func numericFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(DashboardTheme.Typo.mono(size, weight)).monospacedDigit()
    }

    /// The monospaced brand wordmark face.
    func wordmarkFont(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        font(DashboardTheme.Typo.wordmark(size, weight))
    }
}
