import AppKit
import Foundation
import UserNotifications

@MainActor
final class AIFeedStore: ObservableObject {
    @Published private(set) var posts: [AIFeedPost] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var notificationsEnabled: Bool

    private let cache = AIFeedCache()
    private let notificationService = FeedNotificationService()
    private let pushRegistration = BroadcastPushRegistrationService()
    private let defaults = UserDefaults.standard
    private let notificationsKey = "aiFeedNotificationsEnabled"
    private var refreshTask: Task<Void, Never>?

    init() {
        notificationsEnabled = Self.resolvedNotificationsEnabled(
            storedValue: defaults.object(forKey: notificationsKey)
        )

        if let cached = cache.load() {
            let now = Date()
            let earliest = now.addingTimeInterval(-14 * 24 * 60 * 60)
            posts = cached.posts.filter { $0.createdAt >= earliest && $0.createdAt <= now }
            lastUpdated = cached.lastUpdated
        }

        Task { [weak self] in
            await self?.refreshNotificationStatus()
            self?.registerForRemoteNotificationsIfReady()
        }
    }

    var pinnedPosts: [AIFeedPost] {
        posts.filter { $0.priority != .normal }
    }

    var regularPosts: [AIFeedPost] {
        posts.filter { $0.priority == .normal }
    }

    var primaryPosts: [AIFeedPost] {
        AIFeedPost.sortedForDisplay(posts.filter { $0.tier == .primary })
    }

    var rotatingPosts: [AIFeedPost] {
        AIFeedPost.sortedForDisplay(posts.filter { $0.tier == .rotating })
    }

    var recommendedPosts: [AIFeedPost] {
        AIFeedCollectionPolicy.curateForDisplay(posts)
    }

    var importantPosts: [AIFeedPost] {
        recommendedPosts.filter { $0.priority != .normal }
    }

    var morePosts: [AIFeedPost] {
        recommendedPosts.filter { $0.priority == .normal }
    }

    var topStories: [AIFeedPost] {
        Array(posts.prefix(2))
    }

    var sourceTitle: String {
        FeedConfiguration.sourceTitle
    }

    var isSourceConfigured: Bool {
        FeedConfiguration.feedEndpoint != nil
    }

    /// 由状态栏控制器注入:Feed 卡片所在的任一界面(弹窗/仪表板/浮窗)
    /// 可见时返回 true。未注入时视为可见,保持旧行为。
    var uiVisibilityProvider: (() -> Bool)?

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refreshIfVisible()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(FeedConfiguration.pollingIntervalSeconds))
                guard !Task.isCancelled else { return }
                await self?.refreshIfVisible()
            }
        }
    }

    /// Feed 是纯展示内容,没人看时不值得打网络;重要消息本就走推送
    /// 通道送达。界面重新可见时由 refreshIfStale 补拉。
    private func refreshIfVisible() async {
        guard Self.shouldRefreshWhilePolling(
            uiIsVisible: uiVisibilityProvider?()
        ) else { return }
        await refresh()
    }

    /// 界面打开时的补拉:数据比轮询间隔新就不重复请求,避免每次
    /// 点开弹窗都多一次网络往返。
    func refreshIfStale(now: Date = .now) async {
        if let lastUpdated, now.timeIntervalSince(lastUpdated) < FeedConfiguration.pollingIntervalSeconds {
            return
        }
        await refresh()
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: notificationsKey)
        if Self.shouldRequestNotificationPermission(
            notificationsEnabled: enabled,
            authorizationStatus: notificationStatus
        ) {
            await requestNotificationPermission()
        } else {
            await refreshNotificationStatus()
        }

        if enabled {
            registerForRemoteNotificationsIfReady()
        } else {
            NSApp.unregisterForRemoteNotifications()
            if let endpoint = FeedConfiguration.deviceRegistrationEndpoint {
                do {
                    try await pushRegistration.unregister(endpoint: endpoint)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func requestNotificationPermission() async {
        do {
            _ = try await notificationService.requestAuthorization()
        } catch {
            errorMessage = L10n.format("feed.notification_auth_failed", error.localizedDescription)
        }
        await refreshNotificationStatus()
        registerForRemoteNotificationsIfReady()
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        guard notificationsEnabled,
              let endpoint = FeedConfiguration.deviceRegistrationEndpoint
        else { return }
        do {
            try await pushRegistration.register(deviceToken: deviceToken, endpoint: endpoint)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func didFailToRegisterForRemoteNotifications(_ error: Error) {
        guard notificationsEnabled else { return }
        errorMessage = L10n.format("feed.notification_auth_failed", error.localizedDescription)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let endpoint = FeedConfiguration.feedEndpoint else {
            errorMessage = L10n.text("feed.update_unavailable")
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await CuratedFeedService(endpoint: endpoint).fetch()
            let now = Date()
            // The broadcast API owns compact-feed relevance and momentum
            // ranking so every Apple client shows the same featured order.
            posts = Array(fetched.prefix(50))
            lastUpdated = now
            errorMessage = nil
            cache.save(
                .init(
                    posts: posts,
                    seenIDs: Set(posts.map(\.id)),
                    lastUpdated: lastUpdated
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await notificationService.authorizationStatus()
    }

    private func registerForRemoteNotificationsIfReady() {
        guard notificationsEnabled,
              FeedConfiguration.deviceRegistrationEndpoint != nil,
              notificationStatus == .authorized || notificationStatus == .provisional
        else { return }
        NSApp.registerForRemoteNotifications()
    }

    nonisolated static func resolvedNotificationsEnabled(storedValue: Any?) -> Bool {
        (storedValue as? NSNumber)?.boolValue ?? false
    }

    nonisolated static func shouldRequestNotificationPermission(
        notificationsEnabled: Bool,
        authorizationStatus: UNAuthorizationStatus
    ) -> Bool {
        notificationsEnabled && authorizationStatus == .notDetermined
    }

    /// 未注入可见性时保持旧行为;一旦由状态栏控制器提供了
    /// 真实可见性,后台轮询就只在任一 Feed 界面可见时发起。
    nonisolated static func shouldRefreshWhilePolling(uiIsVisible: Bool?) -> Bool {
        uiIsVisible ?? true
    }
}
