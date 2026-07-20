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

/// System material plus restrained brand light. The material keeps the window
/// connected to macOS while the low-opacity gradient preserves UsageDock's
/// Claude/Codex identity beneath the glass surfaces.
struct UsageDockCanvasBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                // Keep the dense, glanceable menu-bar contrast while still
                // letting the system material sample the desktop underneath.
                DashboardTheme.canvas.opacity(0.72)
                LinearGradient(
                    colors: [
                        DashboardTheme.codex.opacity(0.11),
                        Color.clear,
                        DashboardTheme.purple.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
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
