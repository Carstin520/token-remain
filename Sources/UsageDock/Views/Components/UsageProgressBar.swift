import SwiftUI

/// Thin rounded progress bar used for every remaining-quota indicator.
/// `value` is the remaining fraction in `0...1`; the fill uses a provider
/// gradient over a muted track, matching the prototype's quota bars.
struct UsageProgressBar: View {
    let value: Double
    var fill: LinearGradient
    var height: CGFloat = 6
    var track: Color = DashboardTheme.track

    private var clamped: Double { min(1, max(0, value)) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(track)
                Capsule(style: .continuous)
                    .fill(fill)
                    .frame(width: max(0, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
