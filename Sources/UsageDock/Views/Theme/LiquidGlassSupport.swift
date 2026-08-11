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
    /// When supplied, controls the complete backdrop strength. Below the
    /// historical 0.62 default, both the ink and system material fade. Frosted
    /// style keeps a quiet material floor at the transparent end.
    var inkOpacity: Double?
    var glassStyle: PopoverGlassStyle?

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    init(
        inkOpacity: Double? = nil,
        glassStyle: PopoverGlassStyle? = nil
    ) {
        self.inkOpacity = inkOpacity
        self.glassStyle = glassStyle
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                // Cross-faded rather than inserted/removed so switching styles
                // does not pop a whole blur layer into place.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(glassStyle == .clear ? 0 : materialOpacity)
                // Keep environmental blue/red from becoming an accidental app
                // theme. 0.62 remains translucent but reads consistently neutral
                // across bright and strongly colored desktops.
                DashboardTheme.canvas.opacity(
                    inkOpacity ?? UsageDockPopoverAppearance.referenceBackdropOpacity
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
            DashboardTheme.canvas.opacity(inkOpacity ?? 1)
        }
    }

    private var materialOpacity: Double {
        guard let inkOpacity else { return 1 }
        return UsageDockPopoverAppearance.backdropMaterialOpacity(
            backdropOpacity: inkOpacity
        )
    }
}

/// Maps the popup-wide opacity preference onto component surfaces. Text,
/// icons, charts and meters remain fully opaque; only their glass/tint changes.
enum UsageDockPopoverAppearance {
    /// The frosted style retains a quiet native material layer at its
    /// transparent end; clear style removes the material entirely.
    static let minimumBackdropMaterialOpacity = 0.18
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

    static func backdropMaterialOpacity(backdropOpacity: Double) -> Double {
        let progressToReference = progressToReference(backdropOpacity)
        return minimumBackdropMaterialOpacity
            + ((1 - minimumBackdropMaterialOpacity) * progressToReference)
    }

    static func surfaceTintOpacity(backdropOpacity: Double) -> Double {
        min(max(backdropOpacity, 0), 1)
    }

    static func appliesSurfaceTint(backdropOpacity: Double) -> Bool {
        surfaceTintOpacity(backdropOpacity: backdropOpacity) > 0
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

    /// A card's minimum presence at the transparent end. Tinting a card toward
    /// the dark canvas is what previously turned Clear cards near-black, so the
    /// floor is a *lift* (white) instead: enough for the card to read as a pane
    /// of glass rather than an empty outline, far below reading as a fill. It
    /// fades out as the ink tint takes over, so the two never stack.
    static let minimumSurfaceLift = 0.055

    static func surfaceLiftOpacity(backdropOpacity: Double) -> Double {
        minimumSurfaceLift * (1 - progressToReference(backdropOpacity))
    }

    private static func progressToReference(_ backdropOpacity: Double) -> Double {
        min(max(backdropOpacity / referenceBackdropOpacity, 0), 1)
    }

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

extension EnvironmentValues {
    var usageDockPopoverBackdropOpacity: Double? {
        get { self[UsageDockPopoverBackdropOpacityKey.self] }
        set { self[UsageDockPopoverBackdropOpacityKey.self] = newValue }
    }

    var usageDockPopoverGlassStyle: PopoverGlassStyle? {
        get { self[UsageDockPopoverGlassStyleKey.self] }
        set { self[UsageDockPopoverGlassStyleKey.self] = newValue }
    }
}

private struct UsageDockGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let fallbackBackground: Color
    let fallbackBorder: Color

    @Environment(\.usageDockPopoverBackdropOpacity)
    private var popoverBackdropOpacity
    @Environment(\.usageDockPopoverGlassStyle)
    private var popoverGlassStyle
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let baseGlass = resolvedGlass
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                // Sits above the glass and below the label, so a fully
                // transparent Clear card still reads as a pane instead of an
                // empty outline.
                .background {
                    if surfaceLift > 0 {
                        shape.fill(Color.white.opacity(surfaceLift))
                    }
                }
                .glassEffect(
                    interactive ? baseGlass.interactive() : baseGlass,
                    in: shape
                )
                .overlay {
                    if popoverBackdropOpacity != nil {
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
                        .strokeBorder(fallbackBorder, lineWidth: 1)
                )
        }
    }

    @available(macOS 26.0, *)
    private var resolvedGlass: Glass {
        guard let popoverBackdropOpacity else {
            return tint.map { Glass.regular.tint($0) } ?? Glass.regular
        }
        let surfaceColor = tint ?? fallbackBackground
        let surfaceTint: Color? = if UsageDockPopoverAppearance.appliesSurfaceTint(
            backdropOpacity: popoverBackdropOpacity
        ) {
            surfaceColor.opacity(
                UsageDockPopoverAppearance.surfaceTintOpacity(
                    backdropOpacity: popoverBackdropOpacity
                )
            )
        } else {
            // A fully transparent color still resolves as a dark glass tint.
            // Omitting the tint restores the native transparent material.
            nil
        }
        return switch UsageDockPopoverAppearance.surfaceGlassStyle(for: popoverGlassStyle) {
        case .regular:
            Glass.regular.tint(surfaceTint)
        case .clear:
            Glass.clear.tint(surfaceTint)
        }
    }

    private var surfaceLift: Double {
        guard let popoverBackdropOpacity else { return 0 }
        return UsageDockPopoverAppearance.surfaceLiftOpacity(
            backdropOpacity: popoverBackdropOpacity
        )
    }

    private var resolvedFallbackBackground: Color {
        guard let popoverBackdropOpacity else { return fallbackBackground }
        return fallbackBackground.opacity(
            UsageDockPopoverAppearance.surfaceTintOpacity(
                backdropOpacity: popoverBackdropOpacity
            )
        )
    }
}

/// The popup's transparent AppKit panel does not contribute the native
/// `NSPopover` bezel, so the shell has to describe its own edge. It does that
/// with one top-lit hairline rather than another full glass surface: stacking
/// glass behind the cards makes them sample a dark parent and read near-black.
///
/// Applied by the menu-bar panel's chrome only. The floating widget and the
/// macOS 14/15 `NSPopover` already sit inside a system-drawn frame, where a
/// second rim would read as a double edge.
private struct UsageDockPopoverShellModifier: ViewModifier {
    let cornerRadius: CGFloat
    let glassStyle: PopoverGlassStyle

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(DashboardTheme.canvas)
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
        fallbackBackground: Color = DashboardTheme.surface,
        fallbackBorder: Color = DashboardTheme.border
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

    func usageDockPopoverShell(
        cornerRadius: CGFloat,
        glassStyle: PopoverGlassStyle
    ) -> some View {
        modifier(
            UsageDockPopoverShellModifier(
                cornerRadius: cornerRadius,
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
