import SwiftUI

/// One sampling group for nearby custom glass surfaces. On older systems the
/// content is unchanged and continues using the existing dark-card fallback.
struct UsageDockGlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// Neutral popup backdrop. Frosted style samples a system material underneath
/// the ink scrim; clear style removes that blur layer so the native glass
/// surfaces retain crisp refraction. Intentional hues still come from providers,
/// semantic status and actions.
struct UsageDockCanvasBackground: View {
    /// When supplied, controls the ink's strength. Frosted's diffusion is not
    /// part of that: it stays at a fixed thick tier so the style stays
    /// recognisable at every position of the slider.
    var inkOpacity: Double?
    var glassStyle: PopoverGlassStyle?

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    /// The menu-bar panel's shell owns a silhouette this view cannot see (the
    /// beak sits above the content's own bounds), so there the chrome draws the
    /// backdrop for both and this view stands down.
    @Environment(\.usageDockPopoverShellProvidesBackdrop)
    private var shellProvidesBackdrop
    /// Dashboard only: the ink follows the background-lightness preference. In
    /// the popup this stays `.dark`, which is the shipped canvas exactly.
    @Environment(\.dashboardSurfaces)
    private var surfaces

    init(
        inkOpacity: Double? = nil,
        glassStyle: PopoverGlassStyle? = nil
    ) {
        self.inkOpacity = inkOpacity
        self.glassStyle = glassStyle
    }

    var body: some View {
        if shellProvidesBackdrop {
            Color.clear
        } else if #available(macOS 26.0, *) {
            ZStack {
                // Cross-faded rather than inserted/removed so switching styles
                // does not pop a whole blur layer into place. Frosted's tier is
                // fixed: the slider moves the ink below, never the diffusion,
                // or the two styles stop being distinguishable at the ends of
                // the slider's travel.
                Rectangle()
                    .fill(UsageDockPopoverAppearance.frostedMaterial)
                    .opacity(glassStyle == .clear ? 0 : 1)
                // Keep environmental blue/red from becoming an accidental app
                // theme. 0.62 remains translucent but reads consistently neutral
                // across bright and strongly colored desktops. The floor below
                // is the same one the menu-bar shell takes.
                surfaces.canvas.opacity(
                    UsageDockPopoverAppearance.scrimOpacity(
                        backdropOpacity: inkOpacity
                            ?? UsageDockPopoverAppearance.referenceBackdropOpacity
                    )
                )
            }
            .ignoresSafeArea()
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(
                        duration: UsageDockPopoverAppearance.materialTransitionDuration
                    ),
                value: glassStyle
            )
        } else {
            surfaces.canvas.opacity(inkOpacity ?? 1)
        }
    }
}

/// Maps the popup-wide opacity preference onto component surfaces. Text,
/// icons, charts and meters remain fully opaque; only their glass/tint changes.
enum UsageDockPopoverAppearance {
    /// Frosted's identity is diffusion, and diffusion is not something the
    /// opacity slider is allowed to take away.
    ///
    /// It used to be `.ultraThinMaterial` scaled by the slider — the thinnest
    /// blur tier, faded further at the transparent end — so a low slider value
    /// left Frosted looking like plain transparency while Clear's tint grew
    /// murky as the slider rose. Users toggling the setting at different slider
    /// positions saw the two modes swapped, and reported the mapping as
    /// reversed. It was not: neither mode's identity was being carried by its
    /// material.
    ///
    /// Now the material tier is fixed and thick enough that content behind is
    /// unreadable at every slider position, and the slider only moves the scrim
    /// that both modes share.
    static let frostedMaterial: Material = .regularMaterial
    static let foregroundTransitionDuration = 0.16
    /// Switching Clear/Frosted swaps a material rather than a value, so it is
    /// the one popup change that needs an explicit cross-fade to stay
    /// continuous. Kept inside the 150–250 ms band and skipped for Reduce
    /// Motion by the modifiers that apply it.
    static let materialTransitionDuration = 0.20
    /// The opacity at which the popup reaches its historical fully-tinted look.
    /// Both the backdrop material and the per-card lift are expressed as
    /// progress toward this point so nothing changes on a hard threshold.
    static let referenceBackdropOpacity = 0.62

    static func surfaceTintOpacity(backdropOpacity: Double) -> Double {
        min(max(backdropOpacity, 0), 1)
    }

    /// Clear's whole point is that you can see through it. A card tinted at the
    /// full slider value (0.62 canvas by default) resolves as a near-solid dark
    /// pane on `Glass.clear` — the setting then differs from Frosted only in
    /// blur, not in transparency. Clear cards spend a fraction of that
    /// reference on tint instead, so the desktop stays faintly readable through
    /// them while the glyph shadows keep the text legible.
    static let clearSurfaceTintCoefficient = 0.42

    /// The two popup controls own two different parts of the popup: the Glass
    /// style switch owns the *material* of the UI — shell material and card
    /// density both — and the opacity slider owns only the shell scrim's ink.
    /// Card tint is therefore a per-style constant, not a slider mapping:
    /// Frosted keeps its historical fully-tinted card, Clear a fixed
    /// translucent one.
    static func cardTintOpacity(glassStyle: PopoverGlassStyle?) -> Double {
        glassStyle == .clear
            ? referenceBackdropOpacity * clearSurfaceTintCoefficient
            : referenceBackdropOpacity
    }

    /// Floor for the popup's scrim — the flat canvas layer that carries the
    /// slider's ink.
    ///
    /// This is a hit-testing guarantee before it is a visual one. The popup is a
    /// borderless transparent panel, and macOS hit-tests those *per pixel*:
    /// where the window's own backing store is close to fully transparent the
    /// mouse event is delivered to whatever is behind it instead. `glassEffect`
    /// refraction is composited outside that backing store, so a shell made of
    /// nothing but `Glass.clear` leaves alpha ≈ 0 across its whole face —
    /// clicks and hovers fell through to the desktop, and the popup's own
    /// outside-click monitor then read them as a dismissal and closed it.
    ///
    /// A flat colour layer *does* write alpha, so keeping it above the observed
    /// ≈0.05 threshold at every slider position is what makes the popup
    /// clickable at all. The margin over that threshold is deliberate: edge
    /// antialiasing and colour-space rounding both eat into it.
    static let minimumScrimOpacity = 0.12

    /// The popup scrim follows the slider one-to-one above the floor, so the
    /// setting means exactly what it says at every position. A tint on
    /// `Glass.clear` did not: glass saturates, and the previous mapping made
    /// 66% and 30% indistinguishable. A plain colour layer scales linearly and
    /// the whole travel of the slider is visible.
    static func scrimOpacity(backdropOpacity: Double) -> Double {
        max(surfaceTintOpacity(backdropOpacity: backdropOpacity), minimumScrimOpacity)
    }

    /// Preserve the original Frosted card edge curve. Clear uses the newer
    /// top-lit rim below, while Frosted intentionally keeps its pre-redesign
    /// treatment so the two settings remain visually distinct.
    static func borderOpacity(backdropOpacity: Double) -> Double {
        let progress = min(max(backdropOpacity, 0), 1)
        return 0.85 - (0.40 * progress)
    }

    static func surfaceGlassStyle(
        for popoverGlassStyle: PopoverGlassStyle?
    ) -> UsageDockSurfaceGlassStyle {
        popoverGlassStyle == .clear ? .clear : .regular
    }

    // MARK: - Edges

    /// Liquid Glass describes an edge with a light source: a specular arc where
    /// light strikes the top of the curve, a soft shade where it falls away.
    /// One hairline carrying both ends survives bright and dark desktops.
    ///
    /// These are deliberately independent of `backdropOpacity`. Deriving edge
    /// strength from the inverse of the fill made the *most* transparent popup
    /// the *most* heavily outlined one — the opposite of how glass behaves, and
    /// the reason the shell read as a wireframe.
    static func shellRimHighlightOpacity(glassStyle: PopoverGlassStyle?) -> Double {
        glassStyle == .clear ? 0.32 : 0.24
    }

    /// Clear carries slightly more rim than Frosted because Frosted's material
    /// floor already separates the popup from whatever sits behind it.
    static func shellRimShadeOpacity(glassStyle: PopoverGlassStyle?) -> Double {
        glassStyle == .clear ? 0.28 : 0.20
    }

    /// Cards sit on the shell, not on the desktop, so their edge only has to
    /// separate sibling surfaces — `glassEffect` already draws the rest. A full
    /// mid-grey outline at this scale is what turned a stack of transparent
    /// cards into a stack of drawn rectangles.
    static func surfaceRimOpacity(glassStyle: PopoverGlassStyle?) -> Double {
        glassStyle == .clear ? 0.17 : 0.13
    }

    /// Hairline anchoring the footer command area to the content above it.
    static let separatorOpacity = 0.10

    /// Top-lit perimeter for the popup shell. The weakest point of the sweep
    /// still carries ~0.13, so no stretch of the silhouette disappears against
    /// a bright desktop.
    static func shellRimGradient(glassStyle: PopoverGlassStyle?) -> LinearGradient {
        let highlight = shellRimHighlightOpacity(glassStyle: glassStyle)
        let shade = shellRimShadeOpacity(glassStyle: glassStyle)
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(highlight), location: 0),
                .init(color: .white.opacity(highlight * 0.55), location: 0.22),
                .init(color: .white.opacity(highlight * 0.40), location: 0.48),
                .init(color: .black.opacity(shade * 0.45), location: 0.52),
                .init(color: .black.opacity(shade * 0.70), location: 0.78),
                .init(color: .black.opacity(shade), location: 1)
            ],
            // A light source slightly off-axis reads as a curved surface; a
            // perfectly vertical sweep reads as a printed gradient.
            startPoint: UnitPoint(x: 0.32, y: 0),
            endPoint: UnitPoint(x: 0.68, y: 1)
        )
    }

    /// Card rim. No dark end: a card's lower edge sits on the shell rather than
    /// on the desktop, so shading it there would just reinstate a border.
    static func surfaceRimGradient(glassStyle: PopoverGlassStyle?) -> LinearGradient {
        let highlight = surfaceRimOpacity(glassStyle: glassStyle)
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(highlight), location: 0),
                .init(color: .white.opacity(highlight * 0.45), location: 0.42),
                .init(color: .white.opacity(highlight * 0.18), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Material hierarchy

    /// Pointer feedback for popup cards. `Glass.interactive()` is applied to the
    /// same surfaces, but its response is defined against the native untinted
    /// material and did not survive the popup's ink tint in either style when
    /// measured, so the card carries an explicit lift as well.
    ///
    /// The two values are far apart because they are not comparable: measured
    /// on the running popup, a white overlay above a `Glass.clear` card reaches
    /// the screen at its stated opacity, while the same overlay above a
    /// `Glass.regular` card arrives at roughly an eighth of it. These are the
    /// nominal values that render as the *same* lift — about 0.05 effective in
    /// both — not two different design intents. Neither reads as a selected
    /// state: the card brightens, it does not change colour.
    static let clearSurfaceHighlightLift = 0.06
    static let frostedSurfaceHighlightLift = 0.34

    static func surfaceHighlightLift(glassStyle: PopoverGlassStyle?) -> Double {
        glassStyle == .clear ? clearSurfaceHighlightLift : frostedSurfaceHighlightLift
    }

    /// Matches the popup's other foreground-level transitions. Skipped for
    /// Reduce Motion by the view that applies it.
    static let surfaceHighlightTransitionDuration = 0.16

    static func foregroundColor(
        _ role: UsageDockForegroundRole,
        glassStyle: PopoverGlassStyle? = nil
    ) -> Color {
        if glassStyle != nil {
            // Both popup glass styles can cross light and dark desktop content.
            // Keep all hierarchy levels bright enough to survive that movement;
            // the modifier adds a style-specific dark glyph-edge treatment.
            switch role {
            case .primary: return Color(hex: 0xFFFFFF)
            case .secondary: return Color(hex: 0xEDF0F5)
            case .muted: return Color(hex: 0xD2D7E0)
            }
        }
        switch role {
        case .primary: return DashboardTheme.text
        case .secondary: return DashboardTheme.secondaryText
        case .muted: return DashboardTheme.mutedText
        }
    }

    static func glassShadowOpacity(
        _ role: UsageDockForegroundRole,
        glassStyle: PopoverGlassStyle?
    ) -> Double {
        guard let glassStyle else { return 0 }
        let clearGlassOpacity = switch role {
        case .primary: 0.72
        case .secondary: 0.78
        case .muted: 0.84
        }
        return glassStyle == .clear ? clearGlassOpacity : clearGlassOpacity * 0.68
    }
}

enum UsageDockSurfaceGlassStyle {
    case regular
    case clear
}

enum UsageDockForegroundRole {
    case primary
    case secondary
    case muted
}

private struct UsageDockPopoverBackdropOpacityKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

private struct UsageDockPopoverGlassStyleKey: EnvironmentKey {
    static let defaultValue: PopoverGlassStyle? = nil
}

private struct UsageDockPopoverShellProvidesBackdropKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usageDockPopoverBackdropOpacity: Double? {
        get { self[UsageDockPopoverBackdropOpacityKey.self] }
        set { self[UsageDockPopoverBackdropOpacityKey.self] = newValue }
    }

    var usageDockPopoverGlassStyle: PopoverGlassStyle? {
        get { self[UsageDockPopoverGlassStyleKey.self] }
        set { self[UsageDockPopoverGlassStyleKey.self] = newValue }
    }

    /// Set by the menu-bar panel's chrome, which paints one backdrop across the
    /// shell *and* the beak. Everywhere else the content keeps painting its own.
    var usageDockPopoverShellProvidesBackdrop: Bool {
        get { self[UsageDockPopoverShellProvidesBackdropKey.self] }
        set { self[UsageDockPopoverShellProvidesBackdropKey.self] = newValue }
    }
}

private struct UsageDockGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    /// `nil` means "the standard card surface", resolved from the environment
    /// palette so Dashboard cards follow the background-lightness preference
    /// while the popup's explicitly-passed colors are untouched.
    let fallbackBackground: Color?
    let fallbackBorder: Color?

    @Environment(\.usageDockPopoverBackdropOpacity)
    private var popoverBackdropOpacity
    @Environment(\.usageDockPopoverGlassStyle)
    private var popoverGlassStyle
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.dashboardSurfaces)
    private var surfaces

    private var resolvedSurface: Color { fallbackBackground ?? surfaces.surface }
    private var resolvedBorder: Color { fallbackBorder ?? surfaces.border }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let baseGlass = resolvedGlass
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            // One `glassEffect` for every style. Branching the *whole* surface
            // on the style used to remount the glass on every switch, and any
            // construction that leaves a second glass mounted-but-hidden leaks
            // it: `glassEffect` renders in a backdrop layer that an ancestor
            // `.opacity()` does not reach. Only the tint, the lift and the
            // stroke differ between the two settings now, and none of those is
            // glass.
            content
                .glassEffect(
                    interactive ? baseGlass.interactive() : baseGlass,
                    in: shape
                )
                .overlay {
                    if isFrostedPopoverSurface {
                        // The Frosted card edge from before the Clear-glass
                        // redesign, kept so the two settings stay distinct.
                        // Pinned to the reference density: card chrome belongs
                        // to the style switch, the slider only inks the scrim.
                        shape
                            .strokeBorder(
                                resolvedBorder.opacity(
                                    UsageDockPopoverAppearance.borderOpacity(
                                        backdropOpacity:
                                            UsageDockPopoverAppearance.referenceBackdropOpacity
                                    )
                                ),
                                lineWidth: 1
                            )
                            .allowsHitTesting(false)
                    } else if popoverBackdropOpacity != nil {
                        shape
                            .strokeBorder(
                                UsageDockPopoverAppearance.surfaceRimGradient(
                                    glassStyle: popoverGlassStyle
                                ),
                                lineWidth: 1
                            )
                            .allowsHitTesting(false)
                    }
                }
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(
                            duration: UsageDockPopoverAppearance.materialTransitionDuration
                        ),
                    value: popoverGlassStyle
                )
        } else {
            content
                .background(
                    resolvedFallbackBackground,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(resolvedBorder, lineWidth: 1)
                )
        }
    }

    @available(macOS 26.0, *)
    private var resolvedGlass: Glass {
        // Card density belongs to the Glass style switch; the slider only inks
        // the shell scrim. The backdrop-opacity environment value remains the
        // "am I inside the popup" marker guarding this branch.
        guard popoverBackdropOpacity != nil else {
            return tint.map { Glass.regular.tint($0) } ?? Glass.regular
        }
        let surfaceColor = tint ?? resolvedSurface
        let surfaceTint: Color? = surfaceColor.opacity(
            UsageDockPopoverAppearance.cardTintOpacity(glassStyle: popoverGlassStyle)
        )
        return switch UsageDockPopoverAppearance.surfaceGlassStyle(for: popoverGlassStyle) {
        case .regular:
            Glass.regular.tint(surfaceTint)
        case .clear:
            Glass.clear.tint(surfaceTint)
        }
    }

    /// Frosted popup cards keep their pre-redesign composition: full tint, the
    /// old border curve, no white lift.
    private var isFrostedPopoverSurface: Bool {
        popoverGlassStyle == .frosted && popoverBackdropOpacity != nil
    }

    private var resolvedFallbackBackground: Color {
        guard let popoverBackdropOpacity else { return resolvedSurface }
        return resolvedSurface.opacity(
            UsageDockPopoverAppearance.surfaceTintOpacity(
                backdropOpacity: popoverBackdropOpacity
            )
        )
    }
}

/// The popup's transparent AppKit panel does not contribute the native
/// `NSPopover` bezel, so the shell has to describe its own edge. One top-lit
/// hairline traced along the unified silhouette — beak included — so there is
/// no separate V outline to seam against the body.
///
/// Applied by the menu-bar panel's chrome only. The floating widget and the
/// macOS 14/15 `NSPopover` already sit inside a system-drawn frame, where a
/// second rim would read as a double edge.
private struct UsageDockPopoverShellModifier<ShellShape: InsettableShape>: ViewModifier {
    let shape: ShellShape
    let glassStyle: PopoverGlassStyle

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .overlay {
                    shape
                        .strokeBorder(
                            UsageDockPopoverAppearance.shellRimGradient(
                                glassStyle: glassStyle
                            ),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(
                            duration: UsageDockPopoverAppearance.materialTransitionDuration
                        ),
                    value: glassStyle
                )
        } else {
            content
        }
    }
}

/// Backdrop for the menu-bar panel's shell, painted on the unified silhouette
/// so the beak carries the same material as the body.
///
/// Clear is native Liquid Glass for the refraction; Frosted is a fixed thick
/// material for the diffusion. Above either one sits the same flat canvas
/// scrim, and the opacity slider moves only that. Keeping the slider out of the
/// material is what stops the two styles from trading places at the ends of its
/// travel; keeping the scrim above its floor is what keeps the transparent
/// panel clickable — see `UsageDockPopoverAppearance.minimumScrimOpacity`.
///
/// Exactly one of the two is ever mounted. The first version kept both mounted
/// and cross-faded them with `.opacity(0/1)`, which inverted the setting:
/// `glassEffect` draws into a backdrop layer that an ancestor `.opacity()`
/// does not reach, so Clear's refraction kept rendering while Frosted was
/// selected — Frosted looked like the transparent one. `.opacity()` is not a
/// way to hide glass; only unmounting it is.
private struct UsageDockPopoverShellBackdropModifier<ShellShape: Shape>: ViewModifier {
    let shape: ShellShape
    let backdropOpacity: Double
    let glassStyle: PopoverGlassStyle

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background {
                ZStack {
                    if glassStyle == .clear {
                        clearBackdrop
                            .transition(.opacity)
                    } else {
                        frostedBackdrop
                            .transition(.opacity)
                    }
                }
                // Frosted's layers do fade; the glass insert may land as a cut.
                // A correct steady state outranks a continuous switch.
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(
                            duration: UsageDockPopoverAppearance.materialTransitionDuration
                        ),
                    value: glassStyle
                )
            }
        } else {
            // The transparent panel is a macOS 26 surface; older systems keep
            // the system `NSPopover` and its flat canvas fallback.
            content.background(DashboardTheme.canvas)
        }
    }

    /// Clear is two layers on one silhouette: untinted native glass for the
    /// refraction, and a flat scrim above it for the ink.
    ///
    /// The ink is deliberately no longer the glass *tint*. As a tint it was
    /// invisible to hit testing (see `minimumScrimOpacity`) and it saturated
    /// long before the slider ran out, so most of the control's travel changed
    /// nothing on screen. Stacked above the glass instead, it is the dark scrim
    /// the popup was asked for, and it scales linearly.
    @available(macOS 26.0, *)
    private var clearBackdrop: some View {
        ZStack {
            Color.clear.glassEffect(Glass.clear, in: shape)
            shape.fill(DashboardTheme.canvas.opacity(scrimOpacity))
        }
    }

    /// Frosted keeps the same two-part composition — diffusion plus canvas ink —
    /// on the same silhouette. What changed is that the diffusion is now a fixed
    /// thick tier rather than the thinnest one scaled by the slider, so the mode
    /// still reads as frosted with the slider at its transparent end. The ink is
    /// the same scrim Clear uses, floor included: a material is composited
    /// outside the window's backing store just like glass is, so without the
    /// scrim, Frosted at a low slider value was one more way to end up with an
    /// unclickable popup.
    private var frostedBackdrop: some View {
        ZStack {
            Rectangle()
                .fill(UsageDockPopoverAppearance.frostedMaterial)
            DashboardTheme.canvas.opacity(scrimOpacity)
        }
        .clipShape(shape)
    }

    private var scrimOpacity: Double {
        UsageDockPopoverAppearance.scrimOpacity(backdropOpacity: backdropOpacity)
    }
}

private struct UsageDockPopoverSeparatorModifier: ViewModifier {
    @Environment(\.usageDockPopoverGlassStyle)
    private var popoverGlassStyle

    func body(content: Content) -> some View {
        content.overlay(
            popoverGlassStyle == nil
                ? DashboardTheme.border
                : Color.white.opacity(UsageDockPopoverAppearance.separatorOpacity)
        )
    }
}

private struct UsageDockAdaptiveForegroundModifier: ViewModifier {
    let role: UsageDockForegroundRole
    let fixedColor: Color?

    @Environment(\.usageDockPopoverGlassStyle)
    private var popoverGlassStyle
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    func body(content: Content) -> some View {
        let protectsGlassForeground = popoverGlassStyle != nil && fixedColor == nil
        content
            .foregroundStyle(
                fixedColor ?? UsageDockPopoverAppearance.foregroundColor(
                    role,
                    glassStyle: popoverGlassStyle
                )
            )
            .shadow(
                color: protectsGlassForeground
                    ? Color.black.opacity(
                        UsageDockPopoverAppearance.glassShadowOpacity(
                            role,
                            glassStyle: popoverGlassStyle
                        )
                    )
                    : .clear,
                radius: 1.4,
                x: 0,
                y: 0.6
            )
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(
                        duration: UsageDockPopoverAppearance.foregroundTransitionDuration
                ),
                value: popoverGlassStyle
            )
    }
}

private struct UsageDockAdaptiveTintModifier: ViewModifier {
    let role: UsageDockForegroundRole

    @Environment(\.usageDockPopoverGlassStyle)
    private var popoverGlassStyle
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    func body(content: Content) -> some View {
        let color = UsageDockPopoverAppearance.foregroundColor(
            role,
            glassStyle: popoverGlassStyle
        )
        content
            .tint(color)
            .foregroundStyle(color)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(
                        duration: UsageDockPopoverAppearance.foregroundTransitionDuration
                    ),
                value: popoverGlassStyle
            )
    }
}

private struct UsageDockSidebarBackgroundModifier: ViewModifier {
    @Environment(\.dashboardSurfaces)
    private var surfaces

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(surfaces.canvas)
        }
    }
}

private struct UsageDockSidebarListModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.scrollContentBackground(.hidden)
        }
    }
}

private struct UsageDockRoundControlStyleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.plain)
        }
    }
}

private struct UsageDockActionButtonStyleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func usageDockAdaptiveForeground(
        _ role: UsageDockForegroundRole,
        fixedColor: Color? = nil
    ) -> some View {
        modifier(UsageDockAdaptiveForegroundModifier(role: role, fixedColor: fixedColor))
    }

    /// Standard controls such as `Menu` can replace their label's foreground
    /// style. Apply the same adaptive role as a control tint at that boundary.
    func usageDockAdaptiveTint(_ role: UsageDockForegroundRole) -> some View {
        modifier(UsageDockAdaptiveTintModifier(role: role))
    }

    func usageDockGlassSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackBackground: Color? = nil,
        fallbackBorder: Color? = nil
    ) -> some View {
        modifier(
            UsageDockGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                fallbackBackground: fallbackBackground,
                fallbackBorder: fallbackBorder
            )
        )
    }

    func usageDockPopoverShell<ShellShape: InsettableShape>(
        shape: ShellShape,
        glassStyle: PopoverGlassStyle
    ) -> some View {
        modifier(
            UsageDockPopoverShellModifier(
                shape: shape,
                glassStyle: glassStyle
            )
        )
    }

    /// Shell material for the menu-bar panel, drawn on the same closed path as
    /// the clip and the rim.
    func usageDockPopoverShellBackdrop<ShellShape: Shape>(
        shape: ShellShape,
        backdropOpacity: Double,
        glassStyle: PopoverGlassStyle
    ) -> some View {
        modifier(
            UsageDockPopoverShellBackdropModifier(
                shape: shape,
                backdropOpacity: backdropOpacity,
                glassStyle: glassStyle
            )
        )
    }

    /// Hairline that seats the footer command area under the content stack.
    /// Deliberately lighter than `DashboardTheme.border`: at low popup opacity
    /// that palette line reads as drawn chrome floating on the desktop.
    func usageDockPopoverSeparator() -> some View {
        modifier(UsageDockPopoverSeparatorModifier())
    }

    func usageDockSidebarBackground() -> some View {
        modifier(UsageDockSidebarBackgroundModifier())
    }

    func usageDockSidebarListStyle() -> some View {
        modifier(UsageDockSidebarListModifier())
    }

    func usageDockRoundControlStyle() -> some View {
        modifier(UsageDockRoundControlStyleModifier())
    }

    func usageDockActionButtonStyle() -> some View {
        modifier(UsageDockActionButtonStyleModifier())
    }
}
