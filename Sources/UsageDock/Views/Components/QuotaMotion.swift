import AppKit
import SwiftUI

// Quota bars and their remaining figures are the only entrance motion left on
// the Dashboard: bars sweep in and figures roll up every time a page with them
// appears, and each time the menu-bar popup opens. Both run as Core Animation
// in the render server, so the app draws no frames for them. The same motion
// as a SwiftUI animation re-rendered the whole page on every frame, and every
// frame also made AppKit recompute the window's drag region (issue #102).

// MARK: - When the entrance plays

/// What a quota bar or figure does after an update.
enum QuotaEntrance: Equatable {
    /// Empty bar, figure at zeros, waiting for the page to be revealed.
    case zero
    /// Animate from zero to the value.
    case play
    /// Show the value without motion.
    case still

    /// It plays when it first appears on a revealed page, and again each time
    /// `pageRevealed` turns true (the popup opening). `nil`: nothing changed.
    static func next(previous: Bool?, revealed: Bool, animates: Bool) -> QuotaEntrance? {
        guard animates else { return previous == nil || previous != revealed ? .still : nil }
        switch (previous, revealed) {
        case (nil, true), (false?, true): return .play
        case (nil, false), (true?, false): return .zero
        default: return nil
        }
    }
}

extension MotionTiming {
    /// `reveal` as a Core Animation spring.
    static let entranceDuration: TimeInterval = 0.9
    static let entranceBounce: CGFloat = 0.14

    @MainActor
    static func entranceSpring(keyPath: String, on layer: CALayer, from: Any, to: Any) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: entranceDuration, bounce: entranceBounce)
        spring.keyPath = keyPath
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        // The zero state holds on screen through the delay, as in `reveal`.
        let delay = revealDelay.components
        spring.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            + Double(delay.seconds) + Double(delay.attoseconds) / 1e18
        spring.fillMode = .backwards
        return spring
    }
}

// MARK: - Bars

/// A quota bar drawn as Core Animation layers. The lit part sits under a mask
/// that sweeps open from the leading edge.
struct QuotaBarLayer: NSViewRepresentable {
    enum Shape: Equatable {
        case solid
        case segmented(count: Int, gap: CGFloat)
    }

    /// Remaining fraction, `0...1`.
    let fraction: Double
    /// Lit segments for `.segmented`; ignored for `.solid`.
    let litSegments: Int
    let shape: Shape
    let accent: Color
    let track: Color

    func makeNSView(context: Context) -> QuotaBarLayerView {
        QuotaBarLayerView()
    }

    func updateNSView(_ view: QuotaBarLayerView, context: Context) {
        let environment = context.environment
        view.update(
            QuotaBarLayerView.Model(
                fraction: min(1, max(0, fraction)),
                litSegments: litSegments,
                shape: shape,
                accent: accent.resolve(in: environment).cgColor,
                track: track.resolve(in: environment).cgColor
            ),
            revealed: environment.pageRevealed,
            animates: !environment.accessibilityReduceMotion
        )
    }
}

final class QuotaBarLayerView: NSView {
    struct Model {
        var fraction: Double
        var litSegments: Int
        var shape: QuotaBarLayer.Shape
        var accent: CGColor
        var track: CGColor
    }

    private static let sweepKey = "sweep"
    private let trackLayer = CALayer()
    private let litLayer = CALayer()
    private let sweep = CALayer()
    private var model: Model?
    private var revealed: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        sweep.backgroundColor = NSColor.black.cgColor
        sweep.anchorPoint = CGPoint(x: 0, y: 0.5)
        litLayer.mask = sweep
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(litLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        placeLayers()
    }

    func update(_ model: Model, revealed: Bool, animates: Bool) {
        self.model = model
        let step = QuotaEntrance.next(previous: self.revealed, revealed: revealed, animates: animates)
        self.revealed = revealed
        placeLayers()
        if let step { apply(step) }
    }

    private func placeLayers() {
        guard let model else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let bounds = self.bounds
        trackLayer.frame = bounds
        litLayer.frame = bounds
        sweep.bounds = CGRect(origin: .zero, size: bounds.size)
        sweep.position = CGPoint(x: 0, y: bounds.midY)

        let height = bounds.height
        switch model.shape {
        case .solid:
            let track = Self.shapes(in: trackLayer, count: 1)[0]
            let lit = Self.shapes(in: litLayer, count: 1)[0]
            track.frame = bounds
            track.cornerRadius = height / 2
            track.backgroundColor = model.track
            // Any remainder keeps a visible sliver, so a nearly empty window
            // never reads as fully used.
            let width = model.fraction > 0 ? max(height, bounds.width * model.fraction) : 0
            lit.frame = CGRect(x: 0, y: 0, width: min(width, bounds.width), height: height)
            lit.cornerRadius = height / 2
            lit.backgroundColor = model.accent
        case .segmented(let count, let gap):
            let tracks = Self.shapes(in: trackLayer, count: count)
            let lits = Self.shapes(in: litLayer, count: count)
            let width = max(0, (bounds.width - gap * CGFloat(max(0, count - 1))) / CGFloat(max(1, count)))
            for index in 0..<count {
                let frame = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: height)
                for (shape, color) in [(tracks[index], model.track), (lits[index], model.accent)] {
                    shape.frame = frame
                    shape.cornerRadius = 2
                    shape.backgroundColor = color
                }
                lits[index].isHidden = index >= model.litSegments
            }
        }
    }

    private func apply(_ step: QuotaEntrance) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        sweep.removeAnimation(forKey: Self.sweepKey)
        switch step {
        case .zero:
            sweep.transform = CATransform3DMakeScale(0.001, 1, 1)
        case .still:
            sweep.transform = CATransform3DIdentity
        case .play:
            sweep.transform = CATransform3DIdentity
            sweep.add(
                MotionTiming.entranceSpring(keyPath: "transform.scale.x", on: sweep, from: 0.001, to: 1),
                forKey: Self.sweepKey
            )
        }
    }

    /// Exactly `count` rounded sublayers, reusing the ones already there.
    private static func shapes(in container: CALayer, count: Int) -> [CALayer] {
        var layers = container.sublayers ?? []
        while layers.count < count {
            let shape = CALayer()
            shape.cornerCurve = .continuous
            container.addSublayer(shape)
            layers.append(shape)
        }
        while layers.count > count {
            layers.removeLast().removeFromSuperlayer()
        }
        return layers
    }
}

// MARK: - Figures

/// A quota figure ("96.3%", "100% remaining") that rolls its digits up from
/// zero like an odometer when it appears, in Core Animation. Once rolled it is
/// plain SwiftUI text, so the settled figure is exactly what `Text` draws.
struct RollingFigure: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    /// Ink of the rolling digits. The settled text keeps whatever foreground
    /// style its parent applies; pass the same color.
    let color: Color
    /// The glass foreground shadow the popup draws under text, if any.
    var shadowOpacity: Double = 0

    @Environment(\.pageRevealed) private var revealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The columns are only on screen while the figure is at zero or
    /// rolling; afterwards the plain text takes over.
    @State private var settled = false

    init(_ text: String, size: CGFloat, weight: Font.Weight, color: Color, shadowOpacity: Double = 0) {
        self.text = text
        self.size = size
        self.weight = weight
        self.color = color
        self.shadowOpacity = shadowOpacity
    }

    private var rolls: Bool { !settled && !reduceMotion }

    var body: some View {
        Text(text)
            .numericFont(size, weight)
            .opacity(rolls ? 0 : 1)
            .overlay {
                if rolls {
                    RollingFigureLayer(
                        text: text,
                        size: size,
                        weight: weight,
                        color: color,
                        shadowOpacity: shadowOpacity
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .task(id: revealed) {
                guard revealed else {
                    settled = false
                    return
                }
                guard !settled, !reduceMotion else { return }
                try? await Task.sleep(for: MotionTiming.rollSettle)
                guard !Task.isCancelled else { return }
                settled = true
            }
    }

    enum Segment: Equatable {
        case digit(Int)
        case run(String)
    }

    /// `$94.50` → `$`, 9, 4, `.`, 5, 0: each ASCII digit is its own column,
    /// everything between digits stays one run.
    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var run = ""
        for character in text {
            if let value = character.wholeNumberValue, ("0"..."9").contains(character) {
                if !run.isEmpty {
                    segments.append(.run(run))
                    run = ""
                }
                segments.append(.digit(value))
            } else {
                run.append(character)
            }
        }
        if !run.isEmpty { segments.append(.run(run)) }
        return segments
    }
}

private struct RollingFigureLayer: NSViewRepresentable {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    let shadowOpacity: Double

    func makeNSView(context: Context) -> RollingFigureLayerView {
        RollingFigureLayerView()
    }

    func updateNSView(_ view: RollingFigureLayerView, context: Context) {
        let environment = context.environment
        view.update(
            RollingFigureLayerView.Model(
                text: text,
                style: FigureGlyphs.Style(size: size, weight: weight, color: color),
                shadowOpacity: shadowOpacity
            ),
            revealed: environment.pageRevealed,
            animates: !environment.accessibilityReduceMotion
        )
    }
}

private final class RollingFigureLayerView: NSView {
    struct Model: Equatable {
        var text: String
        var style: FigureGlyphs.Style
        var shadowOpacity: Double
    }

    private static let rollKey = "roll"
    private let figure = CALayer()
    /// One per digit: the column of 0–9 that slides inside its clipped slot.
    private var columns: [(digit: Int, column: CALayer)] = []
    private var model: Model?
    private var builtFor: (model: Model, scale: CGFloat)?
    private var revealed: Bool?
    private var atZero = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        figure.shadowColor = NSColor.black.cgColor
        figure.shadowRadius = 1.4
        figure.shadowOffset = CGSize(width: 0, height: -0.6)
        layer?.addSublayer(figure)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        build()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func update(_ model: Model, revealed: Bool, animates: Bool) {
        self.model = model
        let step = QuotaEntrance.next(previous: self.revealed, revealed: revealed, animates: animates)
        self.revealed = revealed
        if let step { atZero = step == .zero }
        build()
        if step == .play { play() }
    }

    private var scale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Lays the figure out from cached glyph images: digit columns in clipped
    /// slots, the text between digits as plain image layers.
    private func build() {
        guard let model else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        figure.shadowOpacity = Float(model.shadowOpacity)
        let scale = self.scale
        if builtFor?.model != model || builtFor?.scale != scale {
            builtFor = (model, scale)
            figure.sublayers?.forEach { $0.removeFromSuperlayer() }
            columns = []
            for segment in RollingFigure.segments(model.text) {
                switch segment {
                case .digit(let digit):
                    let slot = CALayer()
                    slot.masksToBounds = true
                    let column = CALayer()
                    for value in 0...9 {
                        let glyph = CALayer()
                        if let image = FigureGlyphs.image(String(value), style: model.style, scale: scale) {
                            glyph.contents = image.cgImage
                            glyph.contentsScale = scale
                            glyph.bounds = CGRect(origin: .zero, size: image.size)
                        }
                        column.addSublayer(glyph)
                    }
                    slot.addSublayer(column)
                    figure.addSublayer(slot)
                    columns.append((digit, column))
                case .run(let run):
                    let piece = CALayer()
                    if let image = FigureGlyphs.image(run, style: model.style, scale: scale) {
                        piece.contents = image.cgImage
                        piece.contentsScale = scale
                        piece.bounds = CGRect(origin: .zero, size: image.size)
                    }
                    figure.addSublayer(piece)
                }
            }
        }
        place()
    }

    private func place() {
        let pieces = figure.sublayers ?? []
        let widths = pieces.map { piece in
            piece.masksToBounds ? (piece.sublayers?.first?.sublayers?.first?.bounds.width ?? 0) : piece.bounds.width
        }
        let lineHeight = pieces.lazy.map { piece in
            piece.masksToBounds ? (piece.sublayers?.first?.sublayers?.first?.bounds.height ?? 0) : piece.bounds.height
        }.max() ?? 0
        figure.frame = bounds
        let scale = self.scale
        // Centered on the hidden `Text`, so any kerning the pieces lose is
        // split across both ends; whole device pixels keep the glyphs crisp.
        var x = ((bounds.width - widths.reduce(0, +)) / 2 * scale).rounded() / scale
        let y = ((bounds.height - lineHeight) / 2 * scale).rounded() / scale
        var digitIndex = 0
        for (piece, width) in zip(pieces, widths) {
            piece.frame = CGRect(x: x, y: y, width: width, height: lineHeight)
            if piece.masksToBounds, let column = piece.sublayers?.first {
                // Unflipped layer: 0 at the top of the column, 9 at the bottom.
                column.bounds = CGRect(x: 0, y: 0, width: width, height: lineHeight * 10)
                for (value, glyph) in (column.sublayers ?? []).enumerated() {
                    glyph.frame = CGRect(x: 0, y: CGFloat(9 - value) * lineHeight, width: width, height: lineHeight)
                }
                let digit = digitIndex < columns.count ? columns[digitIndex].digit : 0
                column.position = Self.columnPosition(showing: atZero ? 0 : digit, width: width, lineHeight: lineHeight)
                digitIndex += 1
            }
            x += width
        }
    }

    private func play() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (digit, column) in columns {
            column.removeAnimation(forKey: Self.rollKey)
            let width = column.bounds.width
            let lineHeight = column.bounds.height / 10
            let from = Self.columnPosition(showing: 0, width: width, lineHeight: lineHeight)
            let to = Self.columnPosition(showing: digit, width: width, lineHeight: lineHeight)
            column.position = to
            column.add(
                MotionTiming.entranceSpring(keyPath: "position", on: column, from: NSValue(point: from), to: NSValue(point: to)),
                forKey: Self.rollKey
            )
        }
    }

    /// The column's center when `digit` fills its one-line slot.
    private static func columnPosition(showing digit: Int, width: CGFloat, lineHeight: CGFloat) -> CGPoint {
        CGPoint(x: width / 2, y: lineHeight * 5 - CGFloat(9 - digit) * lineHeight)
    }
}

/// Glyph images drawn by SwiftUI itself, in the figure's exact font and ink,
/// cached per style and backing scale. Digits are monospaced, so every column
/// is the same width.
@MainActor
private enum FigureGlyphs {
    struct Style: Hashable {
        var size: CGFloat
        var weight: Font.Weight
        var color: Color
    }

    struct Image {
        let cgImage: CGImage
        let size: CGSize
    }

    private struct Key: Hashable {
        let text: String
        let style: Style
        let scale: CGFloat
    }

    private static var cache: [Key: Image] = [:]

    static func image(_ text: String, style: Style, scale: CGFloat) -> Image? {
        let key = Key(text: text, style: style, scale: scale)
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(
            content: Text(verbatim: text)
                .numericFont(style.size, style.weight)
                .foregroundStyle(style.color)
                .fixedSize()
        )
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let image = Image(
            cgImage: cgImage,
            size: CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
        if cache.count > 512 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
