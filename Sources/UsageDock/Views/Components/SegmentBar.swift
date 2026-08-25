import SwiftUI

/// Pixel-tech segmented meter — the confirmed mobile design's block progress bar.
/// `value` is the *remaining* fraction in `0...1`; filled segments use `accent`,
/// empty segments use `track`. Replaces the old gradient `UsageProgressBar`.
struct SegmentBar: View {
    let value: Double
    var accent: Color
    /// 14 segments in roomy contexts; narrow contexts may pass 10.
    var segments: Int = 14
    var height: CGFloat = 6
    var gap: CGFloat = 3
    /// `nil` follows the environment palette's track color.
    var track: Color?

    @Environment(\.dashboardSurfaces)
    private var surfaces

    private var clamped: Double { min(1, max(0, value)) }

    /// Number of lit segments. Any non-zero remainder lights at least one so a
    /// near-empty window never reads as fully depleted.
    private var filledCount: Int {
        guard segments > 0 else { return 0 }
        let raw = clamped * Double(segments)
        if clamped > 0 && raw < 1 { return 1 }
        return min(segments, Int(raw.rounded()))
    }

    var body: some View {
        HStack(spacing: gap) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < filledCount ? accent : (track ?? surfaces.track))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
