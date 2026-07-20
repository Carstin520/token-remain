import SwiftUI

// MARK: - PixelCard

/// Flat graphite card with a 1px border, four corner "tick" marks and a 2×2 dot
/// cluster — the pixel-tech chrome from the confirmed concept. All ornament is
/// `accessibilityHidden`.
public struct PixelCard<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast

    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    private var borderColor: Color {
        contrast == .increased ? TRTheme.borderHighContrast : TRTheme.border
    }

    public var body: some View {
        content
            // Card text wraps to its ideal height instead of truncating, so every
            // label keeps growing all the way to the AX5 Dynamic Type sizes.
            .fixedSize(horizontal: false, vertical: true)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TRTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .overlay { PixelCorners(color: borderColor) }
    }
}

/// 3×1px L-shaped corner ticks plus a 2×2 dot cluster.
struct PixelCorners: View {
    let color: Color

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let arm: CGFloat = 3
            let inset: CGFloat = 4
            let thickness: CGFloat = 1
            func fill(_ rect: CGRect) { context.fill(Path(rect), with: .color(color)) }

            for x in [inset, size.width - inset - arm] {
                for y in [inset, size.height - inset - thickness] {
                    fill(CGRect(x: x, y: y, width: arm, height: thickness))
                }
            }
            for x in [inset, size.width - inset - thickness] {
                for y in [inset, size.height - inset - arm] {
                    fill(CGRect(x: x, y: y, width: thickness, height: arm))
                }
            }
            // 2×2 dot cluster, bottom-right.
            for row in 0..<2 {
                for column in 0..<2 {
                    fill(CGRect(
                        x: size.width - inset - 8 + CGFloat(column) * 3,
                        y: size.height - inset - 8 + CGFloat(row) * 3,
                        width: 1.5,
                        height: 1.5
                    ))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - SegmentBar

/// Block progress bar. The value is always **remaining**, matching the product's
/// convention on every surface.
public struct SegmentBar: View {
    private let remainingPercent: Double
    private let accent: Color
    private let segments: Int
    private let height: CGFloat

    public init(remainingPercent: Double, accent: Color, segments: Int = 14, height: CGFloat = 6) {
        self.remainingPercent = remainingPercent
        self.accent = accent
        self.segments = segments
        self.height = height
    }

    private var filled: Int {
        let raw = remainingPercent / 100 * Double(segments)
        // Any non-zero remaining keeps at least one lit segment visible.
        return min(segments, max(remainingPercent > 0 ? 1 : 0, Int(raw.rounded())))
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < filled ? accent : TRTheme.track)
                    .frame(height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - PixelBadge

public struct PixelBadge: View {
    private let text: String
    private let accent: Color
    private let filled: Bool

    public init(_ text: String, accent: Color, filled: Bool = false) {
        self.text = text
        self.accent = accent
        self.filled = filled
    }

    public var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(filled ? TRTheme.text : accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(filled ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3).strokeBorder(accent, lineWidth: 1)
            }
    }
}

/// The persistent "演示" mark required on every surface that renders demo numbers.
public struct DemoChip: View {
    private let compact: Bool
    private let expandsHitTarget: Bool

    /// - Parameter expandsHitTarget: pads the accessibility element out to the
    ///   44pt minimum without changing the drawn chip. Set this wherever the chip
    ///   sits in a bar that VoiceOver treats as an interactive region.
    public init(compact: Bool = false, expandsHitTarget: Bool = false) {
        self.compact = compact
        self.expandsHitTarget = expandsHitTarget
    }

    public var body: some View {
        chip
            // Transparent padding grows the element's bounds to the 44pt minimum
            // without changing the drawn chip.
            .padding(expandsHitTarget ? 15 : 0)
            .accessibilityElement()
            .accessibilityLabel(TRL10n.t("demo.a11y"))
            // The chip is a static provenance marker, not a control.
            .accessibilityRespondsToUserInteraction(false)
    }

    private var chip: some View {
        HStack(spacing: 3) {
            // The compact variant lives on fixed-size watch/widget surfaces; the
            // full chip is in-app content and scales with Dynamic Type.
            Text("D̸")
                .font(compact
                    ? .system(size: 8, design: .monospaced).weight(.bold)
                    : .system(.caption, design: .monospaced).weight(.bold))
            if !compact {
                Text(TRL10n.t("demo.chip"))
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .foregroundStyle(TRTheme.indigo)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(TRTheme.indigo, lineWidth: 1) }
    }
}

// MARK: - PixelCheck

/// 5×5 pixel checkbox glyph. `.checked` for a sustainable pace, `.warn` when a
/// window is projected to run out — shape differs, so the signal never relies on colour.
public struct PixelCheck: View {
    public enum Kind: Sendable { case checked, warn }

    private let kind: Kind
    private let size: CGFloat
    private let accent: Color

    public init(_ kind: Kind, size: CGFloat = 11, accent: Color = TRTheme.cyan) {
        self.kind = kind
        self.size = size
        self.accent = accent
    }

    private var pattern: [String] {
        switch kind {
        case .checked:
            return ["....#",
                    "...#.",
                    "#..#.",
                    ".##..",
                    "..#.."]
        case .warn:
            return ["..#..",
                    "..#..",
                    "..#..",
                    ".....",
                    "..#.."]
        }
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, canvasSize in
            let cell = (canvasSize.width / 5).rounded(.down)
            guard cell >= 1 else { return }
            for (row, line) in pattern.enumerated() {
                for (column, character) in line.enumerated() where character == "#" {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * cell,
                            y: CGFloat(row) * cell,
                            width: cell,
                            height: cell
                        )),
                        with: .color(accent)
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - DottedSparkline

public struct DottedSparkline: View {
    private let values: [Double]
    private let accent: Color

    public init(values: [Double], accent: Color = TRTheme.cyan) {
        self.values = values
        self.accent = accent
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard values.count >= 2 else { return }
            let lower = values.min() ?? 0
            let upper = values.max() ?? 100
            let span = max(1, upper - lower)
            let step = size.width / CGFloat(values.count - 1)
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * step
                let normalized = (value - lower) / span
                let y = size.height - CGFloat(normalized) * size.height
                context.fill(
                    Path(CGRect(x: x.rounded() - 1, y: y.rounded() - 1, width: 2, height: 2)),
                    with: .color(accent)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Codex glyph geometry

/// Vector geometry for the Codex identity mark — a six-lobe overlapping "flower"
/// silhouette with a white `>_` command-prompt stroke. Ported verbatim from the
/// user's desktop `CodexBrandGlyph` (`Sources/UsageDock/Views/BrandIcon.swift`) so
/// every Apple surface draws the exact same mark. Kept as pure SwiftUI `Path`
/// geometry (no AppKit) so it renders identically on iOS, watchOS and in widgets.
public enum CodexGlyphGeometry {
    /// The prompt stroke width as a fraction of the glyph's smaller side at
    /// legible sizes. Ported from the desktop `promptStrokeRatio`.
    public static let promptStrokeRatio: CGFloat = 0.115

    /// At tiny sizes the white prompt needs a slightly heavier stroke to stay
    /// readable against the gradient. Below 14pt the ratio steps up.
    public static func promptStrokeRatio(for size: CGFloat) -> CGFloat {
        size < 14 ? 0.145 : promptStrokeRatio
    }

    /// The gradient stops (top → bottom) of the flower fill.
    public static let gradientColors: [Color] = [
        Color(hex: 0xC49AF8),
        Color(hex: 0x6A78FF),
        Color(hex: 0x245BFF)
    ]

    /// Six overlapping rounded lobes joined by a filled centre into one smooth
    /// flower/cloud silhouette. Coordinates are the desktop originals.
    public static func flower(in rect: CGRect) -> Path {
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX + x * rect.width,
                y: rect.minY + y * rect.height,
                width: width * rect.width,
                height: height * rect.height
            )
        }
        var path = Path()
        path.addEllipse(in: ellipse(0.20, 0.20, 0.60, 0.60))
        path.addEllipse(in: ellipse(0.30, 0.04, 0.40, 0.40))
        path.addEllipse(in: ellipse(0.56, 0.16, 0.38, 0.40))
        path.addEllipse(in: ellipse(0.58, 0.45, 0.38, 0.40))
        path.addEllipse(in: ellipse(0.34, 0.58, 0.40, 0.38))
        path.addEllipse(in: ellipse(0.08, 0.44, 0.40, 0.42))
        path.addEllipse(in: ellipse(0.06, 0.16, 0.42, 0.42))
        return path
    }

    /// The white `>_` command prompt: a chevron and an underscore.
    public static func prompt(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.30, 0.34))
        path.addLine(to: point(0.45, 0.50))
        path.addLine(to: point(0.30, 0.66))
        path.move(to: point(0.55, 0.66))
        path.addLine(to: point(0.73, 0.66))
        return path
    }
}

// MARK: - Provider glyph

/// Provider identity marks, ported from the user's newly-applied desktop marks
/// (`Sources/UsageDock/Views/BrandIcon.swift`). Per `design/palette.md` rule 0 each
/// mark carries the vendor's **official brand identity**, never a meter/series colour:
/// - **Claude** — the bundled vendor starburst artwork (`claude.png`), rendered as a
///   template image tinted coral `#D97757`.
/// - **Codex** — the vector six-lobe flower filled with the violet→blue vertical
///   gradient and a white `>_` command-prompt stroke.
public struct ProviderGlyph: View {
    private let provider: ProviderQuota.Provider
    private let size: CGFloat

    public init(provider: ProviderQuota.Provider, size: CGFloat = 16) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        Group {
            switch provider {
            case .claude:
                Image("claude", bundle: .module)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(TRTheme.claudeBrand)
            case .codex:
                Canvas(rendersAsynchronously: false) { context, canvasSize in
                    let rect = CGRect(origin: .zero, size: canvasSize)
                    context.fill(
                        CodexGlyphGeometry.flower(in: rect),
                        with: .linearGradient(
                            Gradient(colors: CodexGlyphGeometry.gradientColors),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        )
                    )
                    context.stroke(
                        CodexGlyphGeometry.prompt(in: rect),
                        with: .color(.white),
                        style: StrokeStyle(
                            lineWidth: min(canvasSize.width, canvasSize.height)
                                * CodexGlyphGeometry.promptStrokeRatio(for: size),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Activity rings

/// Two concentric Apple-Activity-ring-style meters. The outer and inner rings each
/// encode a **remaining** fraction (0…100). Ring colours are the providers' slot
/// accents (violet / cyan) — identity-coloured *meters*, not status colours, per the
/// palette rule that logos carry brand colour while meters carry slot colours. The
/// two rings sit at different radii so they stay distinguishable even in the Lock
/// Screen / watch-face vibrant rendering modes where colour collapses to luminance.
public struct ActivityRings: View {
    private let outerRemaining: Double
    private let innerRemaining: Double
    private let outerColor: Color
    private let innerColor: Color
    private let lineWidth: CGFloat?
    private let centerLabel: String?

    public init(
        outerRemaining: Double,
        innerRemaining: Double,
        outerColor: Color = TRTheme.accent(for: .claude),
        innerColor: Color = TRTheme.accent(for: .codex),
        lineWidth: CGFloat? = nil,
        centerLabel: String? = nil
    ) {
        self.outerRemaining = outerRemaining
        self.innerRemaining = innerRemaining
        self.outerColor = outerColor
        self.innerColor = innerColor
        self.lineWidth = lineWidth
        self.centerLabel = centerLabel
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Apple Activity-rings proportions: two rings of the SAME thickness,
            // sitting immediately adjacent with a hairline gap between them.
            let width = lineWidth ?? side * 0.14
            let gap = max(2, side * 0.045)
            // Ring diameters are sized so each stroke's centreline is a full ring
            // radius (frame-based, never inset toward the centre). The outer stroke's
            // outer edge lands on `side`; the inner ring is one width + gap inside it.
            let outerDiameter = side - width
            let innerDiameter = max(width, outerDiameter - 2 * (width + gap))
            // Text lives inside the inner ring's inner edge with clear padding.
            let textBox = max(0, innerDiameter - width - 4)
            ZStack {
                ring(remaining: outerRemaining, color: outerColor, diameter: outerDiameter, width: width)
                ring(remaining: innerRemaining, color: innerColor, diameter: innerDiameter, width: width)
                if let centerLabel {
                    Text(centerLabel)
                        .font(.system(size: max(8, textBox * 0.42), design: .monospaced).monospacedDigit().weight(.semibold))
                        .foregroundStyle(TRTheme.text)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(width: textBox)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    /// One ring: a faint full-circle track plus the remaining arc, both stroked at
    /// `width` and sized by `diameter` (so the ring stays adjacent, never nested
    /// toward the centre).
    private func ring(remaining: Double, color: Color, diameter: CGFloat, width: CGFloat) -> some View {
        let fraction = max(0, min(1, remaining / 100))
        return ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: width)
            Circle()
                .trim(from: 0.012, to: max(0.012, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Robot-head mark (vector, template-safe)

/// A simplified single-colour robot head — antenna, stroked head, two eye blocks.
/// Drawn as vector geometry so it stays crisp below ~10pt where the bitmap
/// `PixelRobot` matrix muddies, and renders correctly as a template in the Lock
/// Screen / watch-face vibrant modes. Signals "AI" at complication centre sizes.
public struct RobotHeadGlyph: View {
    private let size: CGFloat
    private let color: Color

    public init(size: CGFloat = 16, color: Color = TRTheme.text) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let stroke = max(1, w * 0.08)
            // Antenna.
            var antenna = Path()
            antenna.move(to: CGPoint(x: w * 0.5, y: h * 0.30))
            antenna.addLine(to: CGPoint(x: w * 0.5, y: h * 0.15))
            context.stroke(antenna, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            context.fill(
                Path(ellipseIn: CGRect(x: w * 0.42, y: h * 0.06, width: w * 0.16, height: w * 0.16)),
                with: .color(color)
            )
            // Head.
            let head = CGRect(x: w * 0.18, y: h * 0.30, width: w * 0.64, height: h * 0.50)
            context.stroke(
                Path(roundedRect: head, cornerRadius: w * 0.14),
                with: .color(color),
                lineWidth: stroke
            )
            // Eyes.
            let eyeW = w * 0.14, eyeH = h * 0.14, eyeY = h * 0.47
            for x in [w * 0.31, w * 0.55] {
                context.fill(
                    Path(roundedRect: CGRect(x: x, y: eyeY, width: eyeW, height: eyeH), cornerRadius: 1),
                    with: .color(color)
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Mini dual arc (AI-usage corner mark)

/// A compact "AI usage" mark: two concentric ~270° arcs (outer = Claude, inner =
/// Codex) around a small robot head. On watch-face/lock complications the arcs carry
/// the vendors' **brand** colours (Claude coral, Codex blue) so the mark reads as AI
/// usage at a glance; the two radii keep them distinguishable when hue flattens in
/// vibrant rendering. Drawn in a single `Canvas` for crisp small-size output.
public struct MiniDualArc: View {
    private let outerRemaining: Double
    private let innerRemaining: Double
    private let outerColor: Color
    private let innerColor: Color
    private let size: CGFloat

    /// The 270° gauge sweep, leaving a 90° gap centred at the bottom.
    private static let startDegrees = 135.0
    private static let sweepDegrees = 270.0

    public init(
        outerRemaining: Double,
        innerRemaining: Double,
        outerColor: Color = TRTheme.claudeBrand,
        innerColor: Color = TRTheme.codexBrand,
        size: CGFloat = 28
    ) {
        self.outerRemaining = outerRemaining
        self.innerRemaining = innerRemaining
        self.outerColor = outerColor
        self.innerColor = innerColor
        self.size = size
    }

    private func arc(center: CGPoint, radius: CGFloat, fraction: Double) -> Path {
        var path = Path()
        let clamped = max(0.02, min(1, fraction))
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(Self.startDegrees),
            endAngle: .degrees(Self.startDegrees + Self.sweepDegrees * clamped),
            clockwise: false
        )
        return path
    }

    public var body: some View {
        ZStack {
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                let side = min(canvasSize.width, canvasSize.height)
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let width = side * 0.11
                let gap = max(1.5, side * 0.05)
                let outerRadius = side / 2 - width / 2
                let innerRadius = outerRadius - width - gap

                func draw(_ radius: CGFloat, _ remaining: Double, _ color: Color) {
                    context.stroke(
                        arc(center: center, radius: radius, fraction: 1),
                        with: .color(TRTheme.track),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                    context.stroke(
                        arc(center: center, radius: radius, fraction: remaining / 100),
                        with: .color(color),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                }
                draw(outerRadius, outerRemaining, outerColor)
                draw(innerRadius, innerRemaining, innerColor)
            }
            RobotHeadGlyph(size: size * 0.40, color: TRTheme.text)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Risk badge (semantic)

/// Filled semantic risk badge — conventional green / amber / red field, a short
/// localized label (低/中/高) and the level's glyph (✓ / ! / ‼), so risk is never
/// signalled by hue alone (palette.md v1.1 rule 2). Shared by the widgets and Live
/// Activity; the watch app has its own local twin sized for the smaller screen.
public struct RiskBadge: View {
    private let risk: RiskLevel
    private let compact: Bool

    public init(_ risk: RiskLevel, compact: Bool = false) {
        self.risk = risk
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 3) {
            Text(TRL10n.t("risk.short.\(risk.rawValue)"))
                .font(.system(size: compact ? 9 : 11, design: .monospaced).weight(.bold))
            if !risk.glyph.isEmpty {
                Text(risk.glyph)
                    .font(.system(size: compact ? 8 : 10, design: .monospaced).weight(.bold))
            }
        }
        .foregroundStyle(TRTheme.ink)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(TRTheme.riskSemantic(risk), in: RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

// MARK: - Liquid Glass (iOS 26) with fallback

public extension View {
    /// Applies iOS 26 Liquid Glass where available; below 26 the flat `PixelCard`
    /// surface *is* the design, so the fallback is on-brand rather than degraded.
    @ViewBuilder
    func trGlassCard(enabled: Bool = true) -> some View {
        if enabled, #available(iOS 26.0, watchOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            self
        }
    }
}

/// Primary button style: glass on iOS 26, bordered-prominent below.
public struct TRPrimaryButton: View {
    private let title: String
    private let systemImage: String?
    private let glassEnabled: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        systemImage: String? = nil,
        glassEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.glassEnabled = glassEnabled
        self.action = action
    }

    public var body: some View {
        Group {
            if glassEnabled, #available(iOS 26.0, watchOS 26.0, macOS 26.0, *) {
                button.buttonStyle(.glass)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .tint(TRTheme.indigo)
    }

    private var button: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            // Button labels wrap to their ideal height rather than truncating, so
            // they keep growing through the accessibility Dynamic Type sizes.
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared text styles

public extension Text {
    /// Every numeral in the product is monospaced with tabular digits.
    ///
    /// Fixed-size variant, for widget and complication families whose layouts
    /// cannot reflow. In-app values use `TRValue`, which honours Dynamic Type.
    func trValue(size: CGFloat, weight: Font.Weight = .semibold) -> Text {
        self.font(.system(size: size, weight: weight, design: .monospaced).monospacedDigit())
    }
}

/// A monospaced numeric value that scales with Dynamic Type and caps at
/// `maxSize`, so hero numerals grow at accessibility sizes without overflowing.
public struct TRValue: View {
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private let text: String
    private let size: CGFloat
    private let weight: Font.Weight
    private let maxSize: CGFloat

    public init(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight = .semibold,
        maxSize: CGFloat = .greatestFiniteMagnitude
    ) {
        self.text = text
        self.size = size
        self.weight = weight
        self.maxSize = maxSize
    }

    public var body: some View {
        Text(text)
            .font(.system(size: min(size * scale, maxSize), weight: weight, design: .monospaced)
                .monospacedDigit())
    }
}

#Preview("Components") {
    VStack(alignment: .leading, spacing: 12) {
        PixelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PixelBadge("LOW", accent: TRTheme.violet)
                    DemoChip()
                    Spacer()
                    PixelCheck(.checked)
                }
                SegmentBar(remainingPercent: 46, accent: TRTheme.cyan)
                DottedSparkline(values: [30, 44, 38, 52, 46, 61, 55]).frame(height: 32)
            }
        }
    }
    .padding()
    .background(TRTheme.ink)
}

/// A caption row that lays out horizontally at normal sizes and stacks vertically
/// at accessibility sizes, so label/value pairs never clip instead of growing.
public struct TRAdaptiveRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing / 2) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}
