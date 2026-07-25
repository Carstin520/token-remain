import SwiftUI

/// OpenUsage 式迷你柱状趋势:一行等宽小柱,按最大值归一,末柱(最新一天)
/// 用实色强调,其余用弱化色。零值用贴近基线的小点表达,不会与缺少
/// 视图混淆；纯展示,不可交互。
struct MiniBarChart: View {
    let values: [Double]
    var accent: Color = DashboardTheme.secondaryText
    var barSpacing: CGFloat = 2
    var minBarHeightRatio: CGFloat = 0.08

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let peak = max(values.max() ?? 0, 0)
            let count = CGFloat(values.count)
            let slotWidth = size.width / count
            let barWidth = max(2, min(12, slotWidth - barSpacing))
            for (index, value) in values.enumerated() {
                let isZero = value <= 0 || peak <= 0
                let ratio = isZero ? 0 : max(minBarHeightRatio, value / peak)
                let height = isZero ? min(2, size.height) : size.height * ratio
                let width = isZero ? min(3, barWidth) : barWidth
                let rect = CGRect(
                    x: CGFloat(index) * slotWidth + (slotWidth - width) / 2,
                    y: size.height - height,
                    width: width,
                    height: height
                )
                let isLatest = index == values.count - 1
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(width, height) / 2),
                    with: .color(accent.opacity(isZero ? 0.36 : (isLatest ? 1 : 0.55)))
                )
            }
        }
        .accessibilityHidden(true)
    }
}
