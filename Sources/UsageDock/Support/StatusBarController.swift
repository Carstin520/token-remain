import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let store: UsageStore
    private let feedStore: AIFeedStore
    private let launchAtLogin: LaunchAtLoginManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private lazy var dashboardController = DashboardWindowController(
        store: store,
        feedStore: feedStore,
        launchAtLogin: launchAtLogin
    )
#if DEBUG
    private lazy var popoverPreviewController = PopoverPreviewWindowController(
        store: store,
        launchAtLogin: launchAtLogin,
        onOpenDashboard: { [weak self] section in
            self?.openDashboard(section)
        }
    )
#endif

    init(store: UsageStore, feedStore: AIFeedStore, launchAtLogin: LaunchAtLoginManager) {
        self.store = store
        self.feedStore = feedStore
        self.launchAtLogin = launchAtLogin
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(
            rootView: UsageMenuView(
                store: store,
                launchAtLogin: launchAtLogin,
                onOpenDashboard: { [weak self] section in
                    self?.openDashboard(section)
                }
            )
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        }

        Publishers.CombineLatest(store.$claude, store.$codex)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        updateStatusImage()
        store.start()
        feedStore.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openDashboard(_ section: DashboardSection) {
        popover.performClose(nil)
        dashboardController.show(section: section)
    }

    /// Opens the dashboard when the app is launched with the development-only
    /// `--open-dashboard` argument. Normal menu-bar launches remain unchanged.
    func openDashboardForPreview(section: DashboardSection = .overview) {
        openDashboard(section)
    }

    /// Opens the menu popover for visual QA when launched with
    /// `--open-popover`. Regular launches still wait for a status-item click.
    func openPopoverForPreview() {
#if DEBUG
        popoverPreviewController.show()
#else
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
#endif
    }

    private func updateStatusImage() {
        let height: CGFloat = 18
        let iconSize: CGFloat = 13
        let gap: CGFloat = 4
        let separator = " · "
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let claudeText = NSAttributedString(string: store.claudeRemainingText, attributes: attributes)
        let separatorText = NSAttributedString(string: separator, attributes: attributes)
        let codexText = NSAttributedString(string: store.codexRemainingText, attributes: attributes)
        let width = iconSize + gap + claudeText.size().width
            + separatorText.size().width + iconSize + gap + codexText.size().width

        let image = NSImage(size: NSSize(width: ceil(width), height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        var x: CGFloat = 0
        drawIcon(.claude, at: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
        x += iconSize + gap
        draw(claudeText, x: &x, height: height)
        draw(separatorText, x: &x, height: height)
        drawIcon(.codex, at: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
        x += iconSize + gap
        draw(codexText, x: &x, height: height)

        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Claude 剩余 \(store.claudeRemainingText)；Codex 剩余 \(store.codexRemainingText)"
        statusItem.length = ceil(width) + 8
    }

    private func draw(_ text: NSAttributedString, x: inout CGFloat, height: CGFloat) {
        let size = text.size()
        text.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
        x += size.width
    }

    private func drawIcon(_ provider: ProviderQuota.Provider, at rect: NSRect) {
        let source = BrandIcon.image(for: provider).copy() as! NSImage
        source.isTemplate = false
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
