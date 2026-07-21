import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let store: UsageStore
    private let feedStore: AIFeedStore
    private let launchAtLogin: LaunchAtLoginManager
    private let popoverLayout = PopoverLayoutStore()
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
        feedStore: feedStore,
        launchAtLogin: launchAtLogin,
        layout: popoverLayout,
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
                feedStore: feedStore,
                launchAtLogin: launchAtLogin,
                layout: popoverLayout,
                onOpenDashboard: { [weak self] section in
                    self?.openDashboard(section)
                }
            )
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .noImage
            button.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        Publishers.CombineLatest(store.$claude, store.$codex)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        Publishers.CombineLatest3(store.$cursor, store.$grok, store.$zai)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        // 追踪集合变化(onboarding 确认、额度页增删)即时反映到菜单栏。
        TrackedProvidersStore.shared.$enabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        updateStatusImage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.updateStatusImage()
        }
        store.start()
        feedStore.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverLayout.prepareForPresentation()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            Task { await store.refresh(forceCCUsage: false, forceClaude: false) }
        }
    }

    private func openDashboard(_ section: DashboardSection) {
        popover.performClose(nil)
        dashboardController.show(section: section)
    }

    /// Opens the primary desktop window from app launch, Dock reopen, or menu UI.
    func showDashboard(section: DashboardSection = .overview) {
        openDashboard(section)
    }

    /// Opens the dashboard when the app is launched with the development-only
    /// `--open-dashboard` argument.
    func openDashboardForPreview(section: DashboardSection = .overview) {
        showDashboard(section: section)
    }

    /// Opens the menu popover for visual QA when launched with
    /// `--open-popover`. Regular launches still wait for a status-item click.
    func openPopoverForPreview() {
        popoverLayout.prepareForPresentation()
#if DEBUG
        popoverPreviewController.show()
#else
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
#endif
    }

    private func updateStatusImage() {
        let iconSize: CGFloat = 13
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        // 菜单栏只放 Claude / Codex 中仍在追踪的项;两者都停止追踪时
        // 退化为品牌字样,状态项保持可点击。
        let tracked = TrackedProvidersStore.shared
        var segments: [(ProviderQuota.Provider, String)] = []
        if tracked.isEnabled(.claude) { segments.append((.claude, store.claudeRemainingText)) }
        if tracked.isEnabled(.codex) { segments.append((.codex, store.codexRemainingText)) }

        let title = NSMutableAttributedString()
        if segments.isEmpty {
            title.append(NSAttributedString(string: "TR", attributes: attributes))
        }
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: " · ", attributes: attributes))
            }
            title.append(statusIcon(segment.0, size: iconSize))
            title.append(NSAttributedString(string: " \(segment.1)", attributes: attributes))
        }

        let state = TokenRemainLogoState.resolve(remainingPercent: store.aggregateRemainingPercent)
        statusItem.button?.image = nil
        statusItem.button?.attributedTitle = title
        statusItem.isVisible = true
        NSApp.applicationIconImage = state.image()

        let insights = UsageInsights(
            claude: store.claude,
            codex: store.codex,
            cursor: store.cursor,
            grok: store.grok,
            zai: store.zai,
            others: [store.copilot, store.devin, store.openrouter, store.antigravity, store.opencode]
                .compactMap { $0 },
            daily: nil
        )
        // 菜单栏文字维持 Claude/Codex 两项避免过宽;Cursor 参与聚合
        // 风险(logo 颜色)并出现在 tooltip 与面板里。
        var tooltipLines = [
            "Token Remain · \(state.accessibilityDescription)",
            insights.decisionHeadline()
        ]
        if store.claude != nil {
            tooltipLines.append("Claude 剩余 \(store.claudeRemainingText)")
        }
        if store.codex != nil {
            tooltipLines.append("Codex 剩余 \(store.codexRemainingText)")
        }
        if store.cursor != nil {
            tooltipLines.append("Cursor 剩余 \(store.cursorRemainingText)")
        }
        if let grok = store.grok {
            tooltipLines.append("Grok 剩余 \(UsageFormatting.percent(max(0, 100 - grok.primary.usedPercent)))")
        }
        if let zai = store.zai {
            tooltipLines.append("Z.ai 剩余 \(UsageFormatting.percent(max(0, 100 - zai.primary.usedPercent)))")
        }
        statusItem.button?.toolTip = tooltipLines.joined(separator: "；")
        statusItem.length = ceil(title.size().width) + 8
    }

    private func statusIcon(
        _ provider: ProviderQuota.Provider,
        size: CGFloat
    ) -> NSAttributedString {
        let image = BrandIcon.image(for: provider).copy() as! NSImage
        image.size = NSSize(width: size, height: size)
        image.isTemplate = provider == .claude

        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        attachment.bounds = NSRect(x: 0, y: -2, width: size, height: size)
        return NSAttributedString(attachment: attachment)
    }
}
