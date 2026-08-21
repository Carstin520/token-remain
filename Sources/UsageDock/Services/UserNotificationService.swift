import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    static let tokenRemainOpenAIFeed = Notification.Name("tokenRemain.openAIFeed")
}

/// The app's single owner of `UNUserNotificationCenter`. Only one delegate can
/// be installed per process, so every notification the app posts — feed posts
/// and provider session alerts alike — goes through this one instance;
/// a second one would silently take over foreground presentation and tap
/// routing from the first.
final class UserNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = UserNotificationService()

    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    /// UserNotifications requires a LaunchServices-backed .app bundle on macOS.
    /// SwiftPM's bare `swift run` executable and the test runner have no bundle
    /// proxy, and `UNUserNotificationCenter.current()` raises an Objective-C
    /// exception there before Swift can handle it. Every entry point that
    /// touches `center` has to pass through here.
    private var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && NSRunningApplication.current.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    func requestAuthorization() async throws -> Bool {
        guard isAvailable else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard isAvailable else { return .notDetermined }
        return await center.notificationSettings().authorizationStatus
    }

    func notify(post: AIFeedPost) async {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = post.priority == .tokenReset
            ? L10n.text("feed.notification.title_token")
            : L10n.text("feed.notification.title_major_update")
        content.subtitle = "\(post.displayName) · @\(post.username)"
        content.body = post.text.truncated(to: 180)
        content.sound = .default
        content.userInfo = ["url": post.postURL.absoluteString]

        let request = UNNotificationRequest(
            identifier: "ai-feed-\(post.id)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// A lost provider session is the one failure the app cannot recover from
    /// on its own — only the user can sign in again — and it is also the
    /// easiest to miss, because every card keeps rendering its last good
    /// snapshot. A real sign-out went unnoticed here for 44 hours behind cards
    /// that still showed a plausible quota. So say it out loud rather than only
    /// inside a popover the user has no reason to open.
    ///
    /// Asking for permission at this moment is deliberate: it is the first time
    /// the app has anything urgent to say, and a user who declines still has
    /// the notice on the card.
    func notifyProviderSignedOut(provider: ProviderQuota.Provider) async {
        guard isAvailable else { return }
        switch await authorizationStatus() {
        case .notDetermined:
            guard (try? await requestAuthorization()) == true else { return }
        case .denied:
            return
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = L10n.format("alert.provider_signed_out.title", provider.displayName)
        content.body = L10n.format("alert.provider_signed_out.body", provider.displayName)
        content.sound = .default

        // A stable identifier per provider replaces any earlier copy instead of
        // stacking a new banner on every reminder.
        let request = UNNotificationRequest(
            identifier: "provider-signed-out-\(provider.rawValue)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func clearProviderSignedOut(provider: ProviderQuota.Provider) {
        guard isAvailable else { return }
        center.removeDeliveredNotifications(
            withIdentifiers: ["provider-signed-out-\(provider.rawValue)"]
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let value = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        } else if response.notification.request.content.userInfo["route"] as? String == "feed" {
            NotificationCenter.default.post(name: .tokenRemainOpenAIFeed, object: nil)
        }
        completionHandler()
    }
}

private extension String {
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit - 1)) + "…"
    }
}
