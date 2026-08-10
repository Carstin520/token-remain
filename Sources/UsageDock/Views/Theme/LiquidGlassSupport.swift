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
                if glassStyle != .clear {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(materialOpacity)
                }
                // Keep environmental blue/red from becoming an accidental app
                // theme. 0.62 remains translucent but reads consistently neutral
                // across bright and strongly colored desktops.
                DashboardTheme.canvas.opacity(inkOpacity ?? 0.62)
            }
            .ignoresSafeArea()
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

    static func backdropMaterialOpacity(backdropOpacity: Double) -> Double {
        let progressToHistoricalDefault = min(max(backdropOpacity / 0.62, 0), 1)
        return minimumBackdropMaterialOpacity
            + ((1 - minimumBackdropMaterialOpacity) * progressToHistoricalDefault)
    }

    static func surfaceTintOpacity(backdropOpacity: Double) -> Double {
        min(max(backdropOpacity, 0), 1)
    }

    static func borderOpacity(backdropOpacity: Double) -> Double {
        let progress = min(max(backdropOpacity, 0), 1)
        return 0.85 - (0.40 * progress)
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

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let baseGlass = resolvedGlass
            content.glassEffect(
                interactive ? baseGlass.interactive() : baseGlass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                if let popoverBackdropOpacity {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            fallbackBorder.opacity(
                                UsageDockPopoverAppearance.borderOpacity(
                                    backdropOpacity: popoverBackdropOpacity
                                )
                            ),
                            lineWidth: 1
                        )
                }
            }
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
        // Clear is still native Liquid Glass, but without the dark-mode ink
        // contributed by `regular`. Apply the same 0...1 black-tint curve as
        // the popup backdrop so both layers become transparent together.
        return Glass.clear.tint(
            surfaceColor.opacity(
                UsageDockPopoverAppearance.surfaceTintOpacity(
                    backdropOpacity: popoverBackdropOpacity
                )
            )
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
