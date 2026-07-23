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
            posts = AIFeedPost.sortedForDisplay(
                cached.posts.filter { $0.createdAt >= earliest && $0.createdAt <= now }
            )
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
        Array(AIFeedCollectionPolicy.sortForTrending(posts).prefix(2))
    }

    var sourceTitle: String {
        FeedConfiguration.sourceTitle
    }

    var isSourceConfigured: Bool {
        FeedConfiguration.feedEndpoint != nil
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(FeedConfiguration.pollingIntervalSeconds))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
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
            posts = Array(AIFeedPost.sortedForDisplay(fetched).prefix(50))
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
}
