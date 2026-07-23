import AppKit
import Foundation
import UserNotifications

final class FeedNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        // UserNotifications requires a LaunchServices-backed .app bundle on
        // macOS. SwiftPM's bare `swift run` executable has no bundle proxy and
        // UNUserNotificationCenter.current() would raise an Objective-C
        // exception before Swift can handle it.
        guard Bundle.main.bundleURL.pathExtension == "app",
              NSRunningApplication.current.bundleIdentifier == Bundle.main.bundleIdentifier
        else {
            return .notDetermined
        }
        return await center.notificationSettings().authorizationStatus
    }

    func notify(post: AIFeedPost) async {
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
