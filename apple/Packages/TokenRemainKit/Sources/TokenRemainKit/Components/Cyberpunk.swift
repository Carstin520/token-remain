import SwiftUI

// MARK: - Cyberpunk hero treatment (EXPERIMENT — 2026-07-20)
//
// A self-contained, reversible set of cyberpunk accents applied ONLY to the iOS +
// watch Overview hero surfaces (min-remaining hero %, reset countdown, risk-card
// scanlines, wordmark). To revert the experiment entirely: delete this file and
// undo the call sites in `App/Tabs/OverviewTab.swift` and
// `WatchApp/TokenRemainWatchApp.swift` (search for `PixelDigitText`, `neonGlow`,
// `scanlines`, `ChromaticText`). Nothing else in the product depends on these.
//
// Per the user's explicit request this amends the spec's "pixel feel from chrome,
// not glyphs" rule for the hero numerals only — and does so with vector Canvas
// drawing, never a bundled third-party font.

// MARK: Dot-matrix numerals

/// A custom 5×7 dot-matrix numeral renderer for the minimal set `0-9 % : .`.
/// Drawn in a `Canvas` (round or square dots, ~1pt gap), sized by `size` (the glyph
/// height in points) so it stays crisp from ~16pt (watch) to 64pt (phone hero).
/// Purely decorative — attach accessibility on the wrapping view.
public struct PixelDigitText: View {
    private let text: String
    private let size: CGFloat
    private let color: Color
    private let round: Bool

    public init(_ text: String, size: CGFloat, color: Color = TRTheme.text, round: Bool = true) {
        self.text = text
        self.size = size
        self.color = color
        self.round = round
    }

    /// 7 rows × 5 columns; "1" = lit dot.
    static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        "%": ["11001", "11010", "00100", "01000", "10000", "00011", "00011"],
        ":": ["00000", "00110", "00110", "00000", "00110", "00110", "00000"],
        ".": ["00000", "00000", "00000", "00000", "00000", "00110", "00110"]
    ]

    private static let columns: CGFloat = 5
    private static let rows: CGFloat = 7

    /// Inter-glyph gap as a fraction of a cell.
    private static let gapFraction: CGFloat = 0.5

    private var cell: CGFloat { size / Self.rows }

    private var width: CGFloat {
        let count = CGFloat(text.count)
        guard count > 0 else { return 0 }
        return count * Self.columns * cell + max(0, count - 1) * cell * Self.gapFraction
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            let cell = self.cell
            let dot = cell * 0.82           // ~1pt visual gap at hero sizes
            var x: CGFloat = 0
            for character in text {
                if let pattern = Self.glyphs[character] {
                    for (row, line) in pattern.enumerated() {
                        for (column, value) in line.enumerated() where value == "1" {
                            let rect = CGRect(
                                x: x + CGFloat(column) * cell + (cell - dot) / 2,
                                y: CGFloat(row) * cell + (cell - dot) / 2,
                                width: dot,
                                height: dot
                            )
                            context.fill(round ? Path(ellipseIn: rect) : Path(rect), with: .color(color))
                        }
                    }
                }
                x += Self.columns * cell + cell * Self.gapFraction
            }
        }
        .frame(width: width, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: Neon glow

public extension View {
    /// Layered soft shadows in the value's own accent — a neon bloom for the
    /// dot-matrix numerals (full intensity) and, subtly, the hero-card meters
    /// (`intensity` ~0.4).
    func neonGlow(_ color: Color, intensity: Double = 1) -> some View {
        self
            .shadow(color: color.opacity(0.55 * intensity), radius: 6)
            .shadow(color: color.opacity(0.25 * intensity), radius: 14)
    }
}

// MARK: Scanlines

/// Ultra-subtle horizontal scanlines (1px, low white opacity), for the risk hero
/// card only. Decorative and `accessibilityHidden`.
public struct ScanlineOverlay: View {
    private let spacing: CGFloat
    private let opacity: Double

    public init(spacing: CGFloat = 3, opacity: Double = 0.025) {
        self.spacing = spacing
        self.opacity = opacity
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.white.opacity(opacity))
                )
                y += spacing
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

public extension View {
    /// Overlays scanlines clipped to the card's rounded rect. Disabled when the
    /// user has Reduce Transparency on.
    func scanlines(spacing: CGFloat = 3, cornerRadius: CGFloat = 8) -> some View {
        modifier(ScanlineModifier(spacing: spacing, cornerRadius: cornerRadius))
    }
}

private struct ScanlineModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let spacing: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceTransparency {
                ScanlineOverlay(spacing: spacing)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
    }
}

// MARK: Display-layer numeral

/// The standard "display layer" numeral used across the app for values ≥ ~20pt:
/// dot-matrix `PixelDigitText` with a neon bloom in the value's own accent. Purely
/// visual (accessibility is carried by the enclosing card / an explicit label at the
/// call site). Values below ~16pt should stay SF Mono — the 5×7 matrix muddies.
public struct CyberValue: View {
    private let text: String
    private let size: CGFloat
    private let color: Color
    private let glow: Color

    public init(_ text: String, size: CGFloat, color: Color = TRTheme.text, glow: Color = TRTheme.violet) {
        self.text = text
        self.size = size
        self.color = color
        self.glow = glow
    }

    public var body: some View {
        PixelDigitText(text, size: size, color: color)
            .neonGlow(glow)
    }
}

// MARK: Structure layer — card treatment

public extension View {
    /// Structure-layer card treatment: the ultra-subtle scanline texture over every
    /// card, plus (for key cards) a faint neon border tint in the card's accent.
    /// Scanlines are `accessibilityHidden` and disabled under Reduce Transparency.
    func cyberCard(border: Color? = nil, scanlines: Bool = true, cornerRadius: CGFloat = 8) -> some View {
        modifier(CyberCardModifier(border: border, addScanlines: scanlines, cornerRadius: cornerRadius))
    }

    /// A standalone faint neon border tint (accent ~30%), for surfaces that aren't
    /// `PixelCard`s.
    func neonBorder(_ color: Color, opacity: Double = 0.30, lineWidth: CGFloat = 1, cornerRadius: CGFloat = 8) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(opacity), lineWidth: lineWidth)
        }
    }
}

private struct CyberCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let border: Color?
    let addScanlines: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if addScanlines, !reduceTransparency {
                    ScanlineOverlay()
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(border.opacity(0.30), lineWidth: 1)
                }
            }
    }
}

// MARK: Identity layer — page header

/// A page title rendered in the same static chromatic-aberration treatment as the
/// wordmark, replacing the plain system navigation large title on each tab. The
/// title is the localized tab name (resolved through `TRL10n`), so it reads in the
/// user's system language — there is no separate decorative English eyebrow.
public struct CyberPageHeader: View {
    private let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Dynamic Type text style (not a fixed size) so the header scales and
            // passes the accessibility audit.
            ChromaticText(title, font: .system(.largeTitle, design: .default).weight(.bold), base: TRTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Chromatic wordmark

/// The "Token Remain" wordmark with static ±1pt cyan/magenta ghost offsets — a
/// still chromatic-aberration effect (no animation, so Reduce Motion is a no-op).
public struct ChromaticText: View {
    private let text: String
    private let font: Font
    private let base: Color
    private let offset: CGFloat

    /// Cyberpunk aberration ghosts — cyan and magenta, deliberately outside the
    /// core palette (this is an opt-in experiment on the wordmark only).
    private static let cyanGhost = Color(hex: 0x00E5FF)
    private static let magentaGhost = Color(hex: 0xFF2D95)

    public init(_ text: String, font: Font, base: Color = TRTheme.text, offset: CGFloat = 1) {
        self.text = text
        self.font = font
        self.base = base
        self.offset = offset
    }

    public var body: some View {
        ZStack {
            Text(text).font(font).foregroundStyle(Self.cyanGhost.opacity(0.55)).offset(x: -offset)
            Text(text).font(font).foregroundStyle(Self.magentaGhost.opacity(0.55)).offset(x: offset)
            Text(text).font(font).foregroundStyle(base)
        }
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}
