import SwiftUI

/// Canvas dot-per-sample sparkline in the cyan accent, matching the mobile
/// design's "7 天趋势" card. Ornamental; the underlying values are conveyed
/// textually elsewhere. Renders nothing for fewer than two samples so callers
/// keep an honest empty state rather than fabricating a curve.
struct DottedSparkline: View {
    let values: [Double]
    var accent: Color = DashboardTheme.cyan
    var dotSize: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let range = max(0.0001, maxV - minV)
            let stepX = size.width / CGFloat(values.count - 1)
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let norm = (value - minV) / range
                let y = size.height - CGFloat(norm) * size.height
                let rect = CGRect(
                    x: x - dotSize / 2,
                    y: y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(ellipseIn: rect), with: .color(accent))
            }
        }
        .accessibilityHidden(true)
    }
}
