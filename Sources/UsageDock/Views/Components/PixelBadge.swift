import SwiftUI

/// Uppercase monospaced chip in a 1px-bordered surface — the pixel-tech meta tag
/// from the mobile design. Used for LOW / MEDIUM / HIGH risk, LIVE, HOT,
/// plan names (PROLITE) and other status labels.
struct PixelBadge: View {
    let text: String
    var color: Color = DashboardTheme.secondaryText
    /// When true the chip is a solid `color` field. Per the published palette
    /// rule, filled chips on cyan / warning / danger fields use INK text
    /// (`canvas`, ≈7:1 on red) rather than white — white only reads on violet.
    /// The HIGH risk badge (red field) therefore uses ink text.
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(filled ? DashboardTheme.canvas : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                filled ? color : DashboardTheme.surface2,
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(filled ? Color.clear : color.opacity(0.55), lineWidth: 1)
            )
    }
}
