import SwiftUI

/// Flat pre-macOS 26 pixel card surface: `surface` fill, 1px border and
/// rounded corners. The macOS 26 path keeps system glass instead.
struct PixelCard<Content: View>: View {
    var cornerRadius: CGFloat = 8
    /// `nil` on either of these follows the environment palette.
    var fill: Color?
    var border: Color?
    @ViewBuilder var content: () -> Content

    @Environment(\.dashboardSurfaces)
    private var surfaces

    var body: some View {
        content()
            .background(
                fill ?? surfaces.surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border ?? surfaces.border, lineWidth: 1)
            )
    }
}
