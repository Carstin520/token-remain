import AppKit
import SwiftUI

/// 桌面浮窗(token-monitor 式"桌面固定"显示模式):承载与菜单栏弹窗
/// 完全相同的挂件栈,置顶、跨空间、可整窗拖动,位置记忆。
/// 由设置里的开关控制,与弹窗/仪表板读同一批 store,零额外请求。
@MainActor
final class FloatingWidgetWindowController: NSWindowController, NSWindowDelegate {
    /// 用户点浮窗自己的关闭按钮时,同步回设置开关。
    var onUserClose: (() -> Void)?

    init(
        store: UsageStore,
        feedStore: AIFeedStore,
        launchAtLogin: LaunchAtLoginManager,
        layout: PopoverLayoutStore,
        onOpenDashboard: @escaping (DashboardSection) -> Void
    ) {
        let hosting = NSHostingController(
            rootView: UsageMenuView(
                store: store,
                feedStore: feedStore,
                launchAtLogin: launchAtLogin,
                layout: layout,
                onOpenDashboard: onOpenDashboard
            )
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = "TokenRemain"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = NSColor(srgbRed: 0x07 / 255, green: 0x0B / 255, blue: 0x12 / 255, alpha: 1)
        panel.setFrameAutosaveName("TokenRemainFloatingWidget")

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        guard let window else { return }
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onUserClose?()
    }
}
