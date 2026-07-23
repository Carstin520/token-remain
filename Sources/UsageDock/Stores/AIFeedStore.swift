import Foundation
import UserNotifications

@MainActor
final class AIFeedStore: ObservableObject {
    @Published private(set) var posts: [AIFeedPost] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var hasBearerToken = false
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var selectedRotatingAccounts: [AIFeedAccount] = []

    let primaryAccounts = FeedConfiguration.primaryAccounts
    let rotatingCandidates = FeedConfiguration.rotatingCandidates

    private let tokenStore = KeychainSecretStore(
        service: "com.jamesli.usagedock.xapi",
        account: "bearer-token"
    )
    private let cache = AIFeedCache()
    private let xService = XFeedService()
    private let localConfigurationImporter = LocalFeedConfigurationImporter()
    private let notificationService = FeedNotificationService()
    private let defaults = UserDefaults.standard
    private let notificationsKey = "aiFeedNotificationsEnabled"
    private var seenIDs: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var selectionDayKey: String?

    init() {
        let configured = defaults.object(forKey: notificationsKey)
        // Notification authorization is never a prerequisite for feed refresh
        // or cross-device sync. A fresh install stays off until the user
        // explicitly enables reminders in the AI Feed UI.
        notificationsEnabled = Self.resolvedNotificationsEnabled(storedValue: configured)

        if let cached = cache.load() {
            let now = Date()
            posts = AIFeedCollectionPolicy.mergeDaily(
                existing: cached.posts.map { $0.applyingConfiguredTier() },
                fetched: [],
                dayStart: AIFeedCollectionPolicy.startOfDay(for: now)
            )
            seenIDs = cached.seenIDs
            lastUpdated = cached.lastUpdated
            let todayKey = AIFeedCollectionPolicy.dayKey(for: now)
            if cached.selectionDayKey == todayKey {
                selectionDayKey = todayKey
                selectedRotatingAccounts = Self.accounts(
                    matching: cached.selectedRotatingUsernames ?? [],
                    in: rotatingCandidates
                )
            }
        }

        do {
            hasBearerToken = try tokenStore.read()?.isEmpty == false
        } catch {
            errorMessage = error.localizedDescription
        }

        Task { [weak self] in
            await self?.refreshNotificationStatus()
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

    var requiresBearerToken: Bool {
        FeedConfiguration.delivery.requiresXBearerToken
    }

    var sourceTitle: String {
        FeedConfiguration.delivery.sourceTitle
    }

    var isSourceConfigured: Bool {
        !requiresBearerToken || hasBearerToken
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            if self?.isSourceConfigured == true {
                await self?.refresh()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(FeedConfiguration.pollingIntervalSeconds))
                guard !Task.isCancelled else { return }
                if self?.isSourceConfigured == true {
                    await self?.refresh()
                }
            }
        }
    }

    func saveBearerToken(_ rawValue: String) async -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            errorMessage = L10n.text("feed.enter_bearer_token")
            return false
        }
        do {
            try tokenStore.save(value)
            hasBearerToken = true
            errorMessage = nil
            if Self.shouldRequestNotificationPermission(
                notificationsEnabled: notificationsEnabled,
                authorizationStatus: notificationStatus
            ) {
                await requestNotificationPermission()
            }
            await refresh()
            return errorMessage == nil
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func importLocalConfiguration(from url: URL) async {
        guard requiresBearerToken else { return }
        do {
            let token = try localConfigurationImporter.token(from: url)
            try tokenStore.save(token)
            hasBearerToken = true
            errorMessage = nil
            if Self.shouldRequestNotificationPermission(
                notificationsEnabled: notificationsEnabled,
                authorizationStatus: notificationStatus
            ) {
                await requestNotificationPermission()
            }
            await refresh()
        } catch LocalFeedConfigurationImporter.ImportError.emptyToken {
            // The empty local template is a valid state before the developer
            // supplies a token, so do not surface it as a runtime failure.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeBearerToken() {
        do {
            try tokenStore.delete()
            hasBearerToken = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
    }

    func requestNotificationPermission() async {
        do {
            _ = try await notificationService.requestAuthorization()
        } catch {
            errorMessage = L10n.format("feed.notification_auth_failed", error.localizedDescription)
        }
        await refreshNotificationStatus()
    }

    func refresh() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched: [AIFeedPost]
            let now = Date()
            let dayStart = AIFeedCollectionPolicy.startOfDay(for: now)
            let dayKey = AIFeedCollectionPolicy.dayKey(for: now)
            var rotatingWarning: String?
            var selectedUsernames: [String] = []
            var shouldReplaceRotatingCache = false
            switch FeedConfiguration.delivery {
            case .directXAPI:
                guard let token = try? tokenStore.read(), !token.isEmpty else {
                    hasBearerToken = false
                    return
                }
                let result = try await xService.fetchTiered(
                    bearerToken: token,
                    primaryAccounts: primaryAccounts,
                    rotatingCandidates: rotatingCandidates,
                    startTime: dayStart
                )
                fetched = result.posts
                selectedUsernames = result.selectedRotatingUsernames
                rotatingWarning = result.rotatingWarning
                shouldReplaceRotatingCache = result.rotatingWarning == nil
            case .curatedAPI(let endpoint):
                fetched = try await CuratedFeedService(endpoint: endpoint).fetch()
                shouldReplaceRotatingCache = true
                selectedUsernames = Array(
                    Set(
                        fetched
                            .filter { $0.tier == .rotating }
                            .map { $0.username.lowercased() }
                    )
                )
            }
            let isFirstBaseline = seenIDs.isEmpty
            let newPriorityPosts = fetched.filter {
                !seenIDs.contains($0.id) && $0.priority != .normal
            }

            let retainedPosts = shouldReplaceRotatingCache
                ? posts.filter { $0.tier != .rotating }
                : posts
            posts = AIFeedCollectionPolicy.mergeDaily(
                existing: retainedPosts,
                fetched: fetched,
                dayStart: dayStart
            )
            if !selectedUsernames.isEmpty {
                selectedRotatingAccounts = Self.accounts(
                    matching: selectedUsernames,
                    in: rotatingCandidates
                )
            } else if selectionDayKey != dayKey {
                selectedRotatingAccounts = []
            }
            selectionDayKey = dayKey
            lastUpdated = now
            errorMessage = rotatingWarning

            for post in fetched {
                seenIDs.insert(post.id)
            }
            if seenIDs.count > 500 {
                seenIDs = Set(posts.prefix(300).map(\.id))
            }
            saveCache()

            if !isFirstBaseline && notificationsEnabled && notificationStatus == .authorized {
                for post in newPriorityPosts {
                    await notificationService.notify(post: post)
                }
            }
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

    private func saveCache() {
        cache.save(
            .init(
                posts: posts,
                seenIDs: seenIDs,
                lastUpdated: lastUpdated,
                selectedRotatingUsernames: selectedRotatingAccounts.map(\.username),
                selectionDayKey: selectionDayKey
            )
        )
    }

    private static func accounts(
        matching usernames: [String],
        in candidates: [AIFeedAccount]
    ) -> [AIFeedAccount] {
        var order: [String: Int] = [:]
        for (index, username) in usernames.enumerated() {
            order[username.lowercased()] = order[username.lowercased()] ?? index
        }
        return candidates
            .filter { order[$0.username.lowercased()] != nil }
            .sorted {
                order[$0.username.lowercased(), default: .max]
                    < order[$1.username.lowercased(), default: .max]
            }
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
