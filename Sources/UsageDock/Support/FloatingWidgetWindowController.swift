import AppKit
import SwiftUI

/// 桌面浮窗(token-monitor 式"桌面固定"显示模式):承载与菜单栏弹窗
/// 完全相同的挂件栈,置顶、跨空间、可整窗拖动,位置记忆。
/// 由设置里的开关控制,与弹窗/仪表板读同一批 store,零额外请求。
@MainActor
final class FloatingWidgetWindowController: NSWindowController, NSWindowDelegate {
    /// 用户点浮窗自己的关闭按钮时,同步回设置开关。
    var onUserClose: (() -> Void)?
    private let onBecameVisible: () -> Void
    private var wasActuallyVisible = false
    private var visibilityObserver: NSObjectProtocol?

    init(
        store: UsageStore,
        feedStore: AIFeedStore,
        launchAtLogin: LaunchAtLoginManager,
        layout: PopoverLayoutStore,
        onOpenDashboard: @escaping (DashboardSection) -> Void,
        onBecameVisible: @escaping () -> Void
    ) {
        self.onBecameVisible = onBecameVisible
        let hosting = NSHostingController(
            rootView: UsageMenuView(
                store: store,
                feedStore: feedStore,
                launchAtLogin: launchAtLogin,
                layout: layout,
                usesPopoverBackgroundPreference: false,
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
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateVisibility()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
        }
    }

    func show() {
        guard let window else { return }
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        window.orderFrontRegardless()
        updateVisibility()
    }

    func hide() {
        window?.orderOut(nil)
        wasActuallyVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        wasActuallyVisible = false
        onUserClose?()
    }

    private func updateVisibility() {
        guard let window else { return }
        let isActuallyVisible = window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        defer { wasActuallyVisible = isActuallyVisible }
        if isActuallyVisible && !wasActuallyVisible {
            onBecameVisible()
        }
    }
}
