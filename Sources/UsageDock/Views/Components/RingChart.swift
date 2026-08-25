import SwiftUI

/// A donut chart drawn from proportional segments, with optional center text.
/// Segments are drawn as trimmed circles so no third-party charting is needed
/// and it renders identically on macOS 14.
struct RingChart: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var lineWidth: CGFloat = 18
    var centerText: String?
    var centerCaption: String?
    var centerTextSize: CGFloat = 16
    var highlightedSegmentID: String?
    var onHoverSegment: ((String?) -> Void)?

    private var total: Double {
        max(segments.reduce(0) { $0 + $1.value }, 0)
    }

    /// Running start fraction for each segment.
    private var arcs: [(segment: Segment, start: Double, end: Double)] {
        guard total > 0 else { return [] }
        var running = 0.0
        return segments.map { segment in
            let start = running / total
            running += segment.value
            return (segment, start, running / total)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .inset(by: lineWidth / 2 + 1)
                    .stroke(DashboardSurface.track, lineWidth: lineWidth)

                ForEach(arcs, id: \.segment.id) { arc in
                    let isDimmed = highlightedSegmentID != nil && highlightedSegmentID != arc.segment.id
                    Circle()
                        .inset(by: lineWidth / 2 + 1)
                        .trim(from: arc.start, to: arc.end)
                        .stroke(
                            arc.segment.color.opacity(isDimmed ? 0.32 : 1),
                            style: StrokeStyle(
                                lineWidth: highlightedSegmentID == arc.segment.id ? lineWidth + 2 : lineWidth,
                                lineCap: .butt
                            )
                        )
                        .rotationEffect(.degrees(-90))
                }

                if let centerText {
                    VStack(spacing: 0) {
                        Text(centerText)
                            .numericFont(centerTextSize, .semibold)
                            .usageDockAdaptiveForeground(.primary)

                        if let centerCaption {
                            Text(centerCaption)
                                .font(.system(size: 8, weight: .medium))
                                .usageDockAdaptiveForeground(.muted)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, lineWidth + 3)
                }
            }
            .contentShape(Circle())
            .onContinuousHover { phase in
                guard let onHoverSegment else { return }
                switch phase {
                case .active(let location):
                    onHoverSegment(segmentID(at: location, in: proxy.size))
                case .ended:
                    onHoverSegment(nil)
                }
            }
            .animation(.easeOut(duration: 0.14), value: highlightedSegmentID)
        }
        .accessibilityHidden(true)
    }

    private func segmentID(at location: CGPoint, in size: CGSize) -> String? {
        guard total > 0 else { return nil }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let distance = hypot(location.x - center.x, location.y - center.y)
        let outerRadius = min(size.width, size.height) / 2 - 1
        let innerRadius = max(0, outerRadius - lineWidth - 4)
        guard distance >= innerRadius, distance <= outerRadius else { return nil }

        var degrees = atan2(location.y - center.y, location.x - center.x) * 180 / .pi + 90
        if degrees < 0 { degrees += 360 }
        let fraction = degrees / 360
        return arcs.first(where: { fraction >= $0.start && fraction < $0.end })?.segment.id
    }
}
