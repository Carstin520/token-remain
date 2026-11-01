import SwiftUI

/// The dashboard's motion vocabulary: buttons that press in and spring back
/// with a ripple from the pointer, a switch with a springy knob, and a page
/// entrance where figures roll up and bars fill in.
///
/// Everything here is event-driven and render-only, so no animation re-lays
/// out the page on every frame and nothing runs while the app is idle.
/// Moving and scaling go through `visualEffect`: `.offset` and
/// `.scaleEffect` are geometry effects that SwiftUI resolves in layout, so
/// animating them re-measured the whole scrolling page every frame (the
/// entrance kept the main thread ~80% busy and button springs stuttered).
/// Reduce Motion turns each effect off.
enum MotionTiming {
    static let reveal = Animation.spring(response: 0.9, dampingFraction: 0.86)
    /// When a rolled figure hands over to plain text: after the reveal
    /// spring (plus the popup's small delay) has come to rest.
    static let rollSettle: Duration = .milliseconds(1300)
    /// The entrance waits one beat so the zero state is on screen first.
    static let revealDelay: Duration = .milliseconds(60)
    static let press = Animation.easeOut(duration: 0.08)
    static let release = Animation.spring(response: 0.32, dampingFraction: 0.52)
    static let ripple = Animation.easeOut(duration: 0.55)
    static let rippleLifetime: Duration = .milliseconds(600)
    static let knob = Animation.spring(response: 0.36, dampingFraction: 0.58)
    static let squeeze = Animation.spring(response: 0.22, dampingFraction: 0.7)
    /// The menu-bar popup fades in and out at the window level. It used to
    /// grow out of its beak as well, but scaling the Liquid Glass shell
    /// renders it offscreen: +75 MB of transient GPU memory per opening on
    /// top of the glass's own ~130 MB first render (measured).
    static let popupFadeIn: TimeInterval = 0.18
    static let popupFadeOut: TimeInterval = 0.14
    /// A Dashboard window that was not on screen fades in instead of
    /// appearing in one frame. Longer than the popup's: the window is large,
    /// and the window server spends its first ~70 ms compositing it.
    static let dashboardFadeIn: TimeInterval = 0.32
    /// Starts gently, so the part of the fade spent in that first composite
    /// is not most of it (an ease-out was ~50% opaque by the first frame).
    static let dashboardFadeCurve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    /// The popup's height follows an expanding or collapsing card with the
    /// same spring the card uses, so shell and card move together.
    static let popupResize = Animation.snappy
    /// How long a shrinking popup keeps its larger window, so the shell can
    /// finish collapsing inside it before the window follows.
    static let popupShrinkDelay: TimeInterval = 0.55
}

/// Pure geometry behind the effects, kept apart so it can be tested.
enum MotionGeometry {
    /// A ripple's radius: far enough to cover the corner farthest from the
    /// press point.
    static func rippleReach(from origin: CGPoint, in size: CGSize) -> CGFloat {
        [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            .map { hypot($0.x - origin.x, $0.y - origin.y) }
            .max() ?? 0
    }

    /// The switch track for a control size, matching the system switch.
    static func switchTrack(for controlSize: ControlSize) -> CGSize {
        switch controlSize {
        case .mini: CGSize(width: 26, height: 15)
        case .small: CGSize(width: 32, height: 18)
        default: CGSize(width: 40, height: 22)
        }
    }
}

// MARK: - Page entrance

private struct PageRevealedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while a page plays its entrance: figures read as zeros and
    /// bars as empty, then animate to their values when it turns true.
    /// Outside a revealing page it is always true.
    var pageRevealed: Bool {
        get { self[PageRevealedKey.self] }
        set { self[PageRevealedKey.self] = newValue }
    }
}

extension View {
    /// Plays the entrance when the page appears: figures roll up from zero
    /// and bars fill in. Later data refreshes change values without it.
    func pageReveal() -> some View {
        modifier(PageRevealModifier())
    }

    /// Sweeps this view in from its leading edge during the page entrance.
    func revealSweep() -> some View {
        modifier(RevealSweepModifier())
    }

    /// Grows this view up from its bottom edge during the page entrance.
    func revealGrow() -> some View {
        modifier(RevealGrowModifier())
    }
}

private struct PageRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .environment(\.pageRevealed, revealed || reduceMotion)
            .task {
                guard !revealed, !reduceMotion else { return }
                try? await Task.sleep(for: MotionTiming.revealDelay)
                guard !Task.isCancelled else { return }
                withAnimation(MotionTiming.reveal) { revealed = true }
            }
    }
}

private struct RevealSweepModifier: ViewModifier {
    @Environment(\.pageRevealed) private var revealed

    func body(content: Content) -> some View {
        // A rectangle scaled from the leading edge: no geometry reader per
        // bar, and the scale applies to a plain shape, never to text.
        content.mask(alignment: .leading) {
            Rectangle()
                .visualEffect { content, _ in
                    content.scaleEffect(x: revealed ? 1 : 0.001, y: 1, anchor: .leading)
                }
        }
    }
}

private struct RevealGrowModifier: ViewModifier {
    @Environment(\.pageRevealed) private var revealed

    func body(content: Content) -> some View {
        content.visualEffect { content, _ in
            content.scaleEffect(x: 1, y: revealed ? 1 : 0.02, anchor: .bottom)
        }
    }
}

/// A figure that rolls its digits up from zero during the page entrance, like
/// an odometer: each digit is a 0–9 column that slides to its value.
///
/// Translation only. The system's `.numericText()` transition blurs and
/// scales every glyph, which sends each animation frame through software
/// rendering and leaves glyph bitmaps at a new size in CoreGraphics'
/// process-wide font cache — measured at ~18,000 entries (~46 MB) per
/// Overview visit, never released. Sliding columns rasterize each digit
/// once per font size. Once settled, the figure is plain `Text` again.
struct RollingText: View {
    let text: String
    @Environment(\.pageRevealed) private var revealed
    /// The columns are only on screen while the figure is at zero or
    /// rolling; afterwards the plain text (identical pixels) takes over.
    @State private var settled = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .opacity(settled ? 1 : 0)
            .overlay {
                if !settled {
                    odometer.accessibilityHidden(true)
                }
            }
            .onAppear {
                // Outside an entrance there is nothing to roll.
                if revealed { settled = true }
            }
            .task(id: revealed) {
                guard revealed else {
                    settled = false
                    return
                }
                guard !settled else { return }
                try? await Task.sleep(for: MotionTiming.rollSettle)
                guard !Task.isCancelled else { return }
                settled = true
            }
    }

    private var odometer: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .digit(let value):
                    DigitColumn(digit: revealed ? value : 0)
                case .run(let run):
                    Text(run)
                }
            }
        }
        .fixedSize()
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

    /// `$94.50` → `$00.00`, `73.6%` → `00.0%`; words stay as they are.
    static func zeroed(_ text: String) -> String {
        String(text.map { ("0"..."9").contains($0) ? "0" : $0 })
    }
}

/// One odometer digit: the ten digits stacked in a column, clipped to one
/// line and offset to `digit`. Only the offset animates.
private struct DigitColumn: View {
    let digit: Int

    var body: some View {
        // A hidden "0" sizes the window: digits are monospaced here. Each
        // row of the column is one line, so a row is a tenth of its height.
        Text(verbatim: "0")
            .hidden()
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { value in
                        Text(verbatim: "\(value)")
                    }
                }
                .fixedSize()
                .visualEffect { content, proxy in
                    content.offset(y: -CGFloat(digit) * proxy.size.height / 10)
                }
            }
            .clipped()
    }
}

// MARK: - Buttons

/// Plain buttons that answer the hand: they press in and spring back, and a
/// ripple spreads from where the pointer is. The pointer position lives
/// outside view state, so hovering never redraws; only a press does.
struct PressRippleButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var pressedScale: CGFloat = 0.97
    var rippleColor: Color = .white
    var rippleOpacity: Double = 0.18

    func makeBody(configuration: Configuration) -> some View {
        PressRippleLabel(configuration: configuration, style: self)
    }
}

extension PressRippleButtonStyle {
    /// For the menu-bar popup, whose glass can be light or dark: the ripple
    /// uses the adaptive primary ink instead of white.
    static func popup(cornerRadius: CGFloat, pressedScale: CGFloat = 0.96) -> PressRippleButtonStyle {
        PressRippleButtonStyle(
            cornerRadius: cornerRadius,
            pressedScale: pressedScale,
            rippleColor: .primary,
            rippleOpacity: 0.12
        )
    }
}

/// Where the pointer last was over a button. A plain class kept in
/// `@State`: writing to it does not invalidate the view.
private final class PointerLocation {
    var point: CGPoint?
}

private struct RippleWave: Identifiable {
    let id = UUID()
    let origin: CGPoint?
}

private struct PressRippleLabel: View {
    let configuration: ButtonStyleConfiguration
    let style: PressRippleButtonStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer = PointerLocation()
    @State private var ripples: [RippleWave] = []

    var body: some View {
        configuration.label
            .overlay {
                // Built only while a ripple plays: every button on a page
                // carrying an idle geometry reader made each page build and
                // layout pass measurably slower.
                if !ripples.isEmpty {
                    GeometryReader { proxy in
                        ZStack {
                            ForEach(ripples) { wave in
                                RippleCircle(
                                    wave: wave,
                                    size: proxy.size,
                                    color: style.rippleColor.opacity(style.rippleOpacity)
                                )
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let location) = phase {
                    pointer.point = location
                } else {
                    pointer.point = nil
                }
            }
            .visualEffect { [pressed = configuration.isPressed && !reduceMotion, scale = style.pressedScale] content, _ in
                content.scaleEffect(pressed ? scale : 1)
            }
            .animation(configuration.isPressed ? MotionTiming.press : MotionTiming.release, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed, !reduceMotion else { return }
                let wave = RippleWave(origin: pointer.point)
                ripples.append(wave)
                Task { @MainActor in
                    try? await Task.sleep(for: MotionTiming.rippleLifetime)
                    ripples.removeAll { $0.id == wave.id }
                }
            }
    }
}

private struct RippleCircle: View {
    let wave: RippleWave
    let size: CGSize
    let color: Color
    @State private var spread = false

    var body: some View {
        let origin = wave.origin ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = MotionGeometry.rippleReach(from: origin, in: size)
        Circle()
            .fill(color)
            .frame(width: radius * 2, height: radius * 2)
            .visualEffect { [spread] content, _ in
                content.scaleEffect(spread ? 1 : 0.04)
            }
            .opacity(spread ? 0 : 1)
            .position(origin)
            .onAppear {
                withAnimation(MotionTiming.ripple) { spread = true }
            }
    }
}

// MARK: - Switch

/// The dashboard's switch: the knob springs across with a little overshoot
/// and squashes wide while it is held. Sized from the control size like the
/// system switch, so rows keep their layout; VoiceOver still sees a toggle.
struct ElasticSwitchToggleStyle: ToggleStyle {
    var showsLabel = true
    var tint: Color = DashboardTheme.violet

    func makeBody(configuration: Configuration) -> some View {
        ElasticSwitch(configuration: configuration, showsLabel: showsLabel, tint: tint)
    }
}

private struct ElasticSwitch: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool
    let tint: Color

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHeld = false

    var body: some View {
        HStack(spacing: 8) {
            if showsLabel {
                configuration.label
            }
            track
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private var track: some View {
        let size = MotionGeometry.switchTrack(for: controlSize)
        let inset: CGFloat = 2
        let knob = size.height - inset * 2
        let travel = size.width - knob - inset * 2
        let isOn = configuration.isOn
        return Capsule()
            .fill(isOn ? tint : Color.primary.opacity(0.16))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.1), lineWidth: 0.5))
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
                    // Held, the knob squashes wide toward its travel.
                    .visualEffect { [isHeld, isOn] content, _ in
                        content
                            .scaleEffect(x: isHeld ? 1.3 : 1, y: isHeld ? 0.9 : 1, anchor: isOn ? .trailing : .leading)
                            .offset(x: inset + (isOn ? travel : 0))
                    }
            }
            .animation(reduceMotion ? nil : MotionTiming.knob, value: isOn)
            .animation(reduceMotion ? nil : MotionTiming.squeeze, value: isHeld)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHeld { isHeld = true }
                    }
                    .onEnded { _ in
                        isHeld = false
                        guard isEnabled else { return }
                        configuration.isOn.toggle()
                    }
            )
    }
}
