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

/// Neutral system material. A substantial ink scrim suppresses unrelated
/// wallpaper/window colors while retaining enough translucency for native glass
/// depth. Intentional hues come from providers, semantic status and actions.
struct UsageDockCanvasBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                // Keep environmental blue/red from becoming an accidental app
                // theme. 0.62 remains translucent but reads consistently neutral
                // across bright and strongly colored desktops.
                DashboardTheme.canvas.opacity(0.62)
            }
            .ignoresSafeArea()
        } else {
            DashboardTheme.canvas
        }
    }
}

private struct UsageDockGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let fallbackBackground: Color
    let fallbackBorder: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let baseGlass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            content.glassEffect(
                interactive ? baseGlass.interactive() : baseGlass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    fallbackBackground,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(fallbackBorder, lineWidth: 1)
                )
        }
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
