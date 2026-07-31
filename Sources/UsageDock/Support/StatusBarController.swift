import AppKit
import Combine
import SwiftUI

enum StatusBarPresentation {
    /// Menu-bar choices are display preferences, not ranking candidates. Keep
    /// every configured provider that is still tracked, in the user's order.
    static func visibleProviders(
        configured: [ProviderQuota.Provider],
        tracked: Set<ProviderQuota.Provider>
    ) -> [ProviderQuota.Provider] {
        configured.filter(tracked.contains)
    }

    /// The display mode controls density only. The provider selection remains
    /// the user's source of truth; only minimal mode intentionally reduces it.
    static func displayedProviders(
        mode: MenuBarDisplayMode,
        selected: [ProviderQuota.Provider],
        remainingPercent: [ProviderQuota.Provider: Double]
    ) -> [ProviderQuota.Provider] {
        guard mode == .minimal else { return selected }
        guard let mostConstrained = selected.min(by: { lhs, rhs in
            (remainingPercent[lhs] ?? .infinity) < (remainingPercent[rhs] ?? .infinity)
        }) else {
            return []
        }
        return [mostConstrained]
    }

    static func primaryRemainingPercent(in quota: ProviderQuota?) -> Double? {
        quota.map { min(100, max(0, 100 - $0.primary.usedPercent)) }
    }

    static func remainingText(for quota: ProviderQuota?) -> String {
        guard let primary = primaryRemainingPercent(in: quota) else { return "—" }
        return UsageFormatting.percent(primary)
    }
}

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
    private lazy var floatingWidgetController: FloatingWidgetWindowController = {
        let controller = FloatingWidgetWindowController(
            store: store,
            feedStore: feedStore,
            launchAtLogin: launchAtLogin,
            layout: popoverLayout,
            onOpenDashboard: { [weak self] section in
                self?.openDashboard(section)
            }
        )
        controller.onUserClose = {
            PreferencesStore.shared.setFloatingWidgetEnabled(false)
        }
        return controller
    }()

    private var floatingControllerCreated = false
    private var dashboardCreated = false
    /// 上一次真正应用到菜单栏/Dock 的显示内容指纹与 Dock 图标内容键。
    private var lastStatusFingerprint: String?
    private var lastDockIconKey: String?

    private func setFloatingWidget(visible: Bool) {
        if visible {
            floatingControllerCreated = true
            popoverLayout.prepareForPresentation()
            floatingWidgetController.show()
            store.refreshLocalUsage()
            refreshFeedIfStale()
        } else if floatingControllerCreated {
            floatingWidgetController.hide()
        }
    }
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

        // AppKit cannot choose a fixed right-edge position: macOS owns status
        // item ordering and the user may Command-drag it. A stable autosave name
        // preserves that user-selected position and visibility across launches.
        statusItem.autosaveName = "TokenRemainPrimaryStatusItem"
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

        // 任意额度数据变化都重绘菜单栏(objectWillChange 覆盖全部 provider,
        // receive(on:) 把执行推迟到赋值完成后的下一个 runloop)。
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        // 追踪集合与菜单栏自选变化(onboarding 确认、额度页增删、设置调整)
        // 即时反映到菜单栏。
        TrackedProvidersStore.shared.$enabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        // TokenRemain 运行期间检测到用户后来安装的新工具时，主动打开额度页
        // 并由 Dashboard 询问是否接入。队列只包含尚未追踪的新安装。
        TrackedProvidersStore.shared.$pendingDetectionSuggestions
            .dropFirst()
            .compactMap { $0.first }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openDashboard(.limits) }
            .store(in: &cancellables)

        PreferencesStore.shared.$menuBarProviders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        PreferencesStore.shared.$menuBarDisplayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusImage() }
            .store(in: &cancellables)

        // 桌面浮窗随设置开关。
        PreferencesStore.shared.$floatingWidgetEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in self?.setFloatingWidget(visible: enabled) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusImage()
                // 切回前台不强制扫描:相关界面可见时分钟级节奏本就在跑,
                // 都不可见时按用户刷新偏好补扫即可。
                self?.store.refreshLocalUsage(force: false)
                TrackedProvidersStore.shared.scanForNewInstallations()
            }
            .store(in: &cancellables)

        updateStatusImage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.updateStatusImage()
        }
        store.localUsageUIVisibilityProvider = { [weak self] in
            self?.isPrimarySurfaceVisible ?? false
        }
        feedStore.uiVisibilityProvider = { [weak self] in
            self?.isPrimarySurfaceVisible ?? false
        }
        store.start()
        feedStore.start()
        TrackedProvidersStore.shared.startDetectionMonitoring()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverLayout.prepareForPresentation()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            store.refreshLocalUsage()
            refreshFeedIfStale()
        }
    }

    /// 界面从不可见转为可见时,Feed 若比轮询间隔旧就补拉一次;
    /// 后台被门控跳过的轮次由这里衔接。
    private func refreshFeedIfStale() {
        Task { [weak self] in
            await self?.feedStore.refreshIfStale()
        }
    }

    private func openDashboard(_ section: DashboardSection) {
        popover.performClose(nil)
        dashboardCreated = true
        dashboardController.show(section: section)
        store.refreshLocalUsage()
        refreshFeedIfStale()
    }

    /// 本地用量与 AI Feed 是否正被某个界面展示。仅在这些界面可见时,
    /// 才值得维持分钟级 ccusage 扫描与 Feed 轮询(Apple 设备同步开启时
    /// ccusage 另行保持分钟级);检查必须避开未创建的 lazy 控制器,
    /// 不能为了读可见性把窗口先建出来。
    private var isPrimarySurfaceVisible: Bool {
        if popover.isShown { return true }
        if dashboardCreated, dashboardController.window?.isVisible == true { return true }
        if floatingControllerCreated, floatingWidgetController.window?.isVisible == true { return true }
        return false
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
        store.refreshLocalUsage()
#if DEBUG
        popoverPreviewController.show()
#else
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
#endif
    }

    private func updateStatusImage() {
        // provider 选择与显示密度是两个独立设置。完整/紧凑模式保留全部
        // 勾选项；只有用户明确选择极简模式时才显示最低余额的一项。
        let tracked = TrackedProvidersStore.shared
        let selectedProviders = StatusBarPresentation.visibleProviders(
            configured: PreferencesStore.shared.menuBarProviders,
            tracked: tracked.enabled
        )
        let remainingPercent = Dictionary(
            uniqueKeysWithValues: selectedProviders.compactMap { provider in
                let quota = store.quotaValue(for: provider)
                return StatusBarPresentation.primaryRemainingPercent(in: quota)
                    .map { (provider, $0) }
            }
        )
        let displayMode = PreferencesStore.shared.menuBarDisplayMode
        let displayedProviders = StatusBarPresentation.displayedProviders(
            mode: displayMode,
            selected: selectedProviders,
            remainingPercent: remainingPercent
        )
        let segments: [(ProviderQuota.Provider, String)] = displayedProviders.map { provider in
            let remaining = StatusBarPresentation.remainingText(for: store.quotaValue(for: provider))
            return (provider, remaining)
        }

        let claudeRemaining = UsageStore.logoQuotaSelection(from: [store.quotaValue(for: .claude)])?.remainingPercent
        let codexRemaining = UsageStore.logoQuotaSelection(from: [store.quotaValue(for: .codex)])?.remainingPercent
        let state = TokenRemainLogoState.resolve(
            remainingPercent: [claudeRemaining, codexRemaining].compactMap { $0 }.min()
        )
        let dockIconKey = TokenRemainHeadLogoArtwork.renderKey(
            claudeRemaining: claudeRemaining,
            codexRemaining: codexRemaining
        )

        let insights = UsageInsights(
            claude: nil,
            codex: nil,
            others: Array(store.quotas.values),
            daily: nil
        )
        // 菜单栏文字维持用户自选项;Dock logo 的表情与双进度条只比较
        // Claude/Codex，其他 provider 仍出现在 tooltip 与面板里。
        var tooltipLines = [
            "TokenRemain · \(state.accessibilityDescription)",
            insights.decisionHeadline()
        ]
        for provider in ProviderQuota.Provider.displayOrder {
            guard let quota = store.quotaValue(for: provider) else { continue }
            let remaining = UsageFormatting.percent(max(0, 100 - quota.primary.usedPercent))
            tooltipLines.append(L10n.format("statusbar.tooltip_remaining", provider.displayName, remaining))
        }
        let tooltip = tooltipLines.joined(separator: L10n.text("statusbar.tooltip_separator"))

        // objectWillChange 覆盖 UsageStore 的每一次 @Published 赋值,一轮
        // 刷新会触发本方法十余次,其中绝大多数并不改变任何可见内容。
        // 先算显示指纹,不变就整体跳过,避免反复重建富文本与 Dock 重绘。
        let fingerprint = [
            displayMode.rawValue,
            segments.map { "\($0.0.rawValue):\($0.1)" }.joined(separator: ","),
            dockIconKey,
            tooltip
        ].joined(separator: "|")
        guard fingerprint != lastStatusFingerprint else { return }
        lastStatusFingerprint = fingerprint

        let iconSize: CGFloat = 13
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let title = NSMutableAttributedString()
        if segments.isEmpty {
            title.append(NSAttributedString(string: "TR", attributes: attributes))
        }
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let separator = displayMode == .compact ? " " : " · "
                title.append(NSAttributedString(string: separator, attributes: attributes))
            }
            title.append(statusIcon(segment.0, size: iconSize))
            if displayMode != .compact {
                title.append(NSAttributedString(string: " \(segment.1)", attributes: attributes))
            }
        }

        statusItem.button?.image = nil
        statusItem.button?.attributedTitle = title
        statusItem.isVisible = true
        statusItem.button?.toolTip = tooltip
        statusItem.length = ceil(title.size().width) + 4

        // 给 applicationIconImage 赋值本身就会强制一次完整的 Dock 瓦片
        // 渲染(含色彩转换),与图片对象是否复用无关,必须按内容去重。
        // Dock 与应用切换器的实际显示不超过 128pt@2x,256px 渲染足够,
        // 单张位图成本也从 ~4MB 降到 ~256KB。
        if dockIconKey != lastDockIconKey {
            lastDockIconKey = dockIconKey
            NSApp.applicationIconImage = TokenRemainHeadLogoArtwork.image(
                claudeRemaining: claudeRemaining,
                codexRemaining: codexRemaining,
                size: 256
            )
        }
    }

    private func statusIcon(
        _ provider: ProviderQuota.Provider,
        size: CGFloat
    ) -> NSAttributedString {
        let image = BrandIcon.image(for: provider).copy() as! NSImage
        image.size = NSSize(width: size, height: size)

        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        attachment.bounds = NSRect(x: 0, y: -2, width: size, height: size)
        return NSAttributedString(attachment: attachment)
    }
}
