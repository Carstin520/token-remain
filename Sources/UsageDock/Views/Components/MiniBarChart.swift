import SwiftUI

/// OpenUsage 式迷你柱状趋势:一行等宽小柱,按最大值归一,末柱(最新一天)
/// 用实色强调,其余用弱化色。纯展示,不可交互;空数据渲染为空白。
struct MiniBarChart: View {
    let values: [Double]
    var accent: Color = DashboardTheme.secondaryText
    var barSpacing: CGFloat = 2
    var minBarHeightRatio: CGFloat = 0.08

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty, let peak = values.max(), peak > 0 else { return }
            let count = CGFloat(values.count)
            let barWidth = max(1, (size.width - barSpacing * (count - 1)) / count)
            for (index, value) in values.enumerated() {
                // 有量的日子至少画出一个可见短柱,零值留空。
                let ratio = value <= 0 ? 0 : max(minBarHeightRatio, value / peak)
                guard ratio > 0 else { continue }
                let height = size.height * ratio
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + barSpacing),
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                let isLatest = index == values.count - 1
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth * 0.3),
                    with: .color(accent.opacity(isLatest ? 1 : 0.55))
                )
            }
        }
        .accessibilityHidden(true)
    }
}
