import SwiftUI

/// 弹窗滚动视图的液态玻璃替身:隐藏系统滚动条,改用一条 3pt 宽的玻璃
/// 指示条——滚动时浮现在右缘,停止约一秒后淡出。指示条纯展示、不参与
/// 命中,滚动仍由触控板/滚轮驱动;这换来它可以做得远比 NSScroller 细,
/// 并与设置面板滑块的玻璃拇指共用同一套材质语言(透明白渐变,纯绘制,
/// 不做 glassEffect 背景采样)。
struct LiquidGlassScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isScrolling = false
    @State private var fadeOutTask: Task<Void, Never>?

    /// 只用于读滚动 offset 的私有坐标系;调用方仍可在外面叠加自己的
    /// named coordinate space(例如弹窗的拖拽重排),互不干扰。
    /// (泛型类型不允许静态存储属性,所以是计算属性。)
    private static var spaceName: String { "liquidGlassScroll" }

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.spaceName))
                } action: { frame in
                    contentHeight = frame.height
                    offsetDidChange(-frame.minY)
                }
        }
        .coordinateSpace(name: Self.spaceName)
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            viewportHeight = height
        }
        .overlay(alignment: .topTrailing) { indicator }
    }

    private func offsetDidChange(_ newOffset: CGFloat) {
        // 首帧和内容高度变化会以同一 offset 重新上报;半点以内的抖动
        // 不该让指示条闪现。
        guard abs(newOffset - offset) > 0.5 else { return }
        offset = newOffset
        withAnimation(.easeOut(duration: 0.12)) { isScrolling = true }
        fadeOutTask?.cancel()
        fadeOutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.45)) { isScrolling = false }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        let scrollableRange = contentHeight - viewportHeight
        if scrollableRange > 1, viewportHeight > 0 {
            let inset: CGFloat = 4
            let trackHeight = max(0, viewportHeight - inset * 2)
            let thumbHeight = min(
                trackHeight,
                max(28, trackHeight * viewportHeight / max(contentHeight, 1))
            )
            let progress = min(1, max(0, offset / scrollableRange))
            let travel = max(0, trackHeight - thumbHeight)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.26)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .frame(width: 4, height: thumbHeight)
                .shadow(color: Color.black.opacity(0.3), radius: 1.5)
                .padding(.trailing, 3)
                .offset(y: inset + travel * progress)
                .opacity(isScrolling ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
