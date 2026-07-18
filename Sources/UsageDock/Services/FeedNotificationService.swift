import AppKit
import Foundation
import UserNotifications

final class FeedNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func notify(post: AIFeedPost) async {
        let content = UNMutableNotificationContent()
        content.title = post.priority == .tokenReset ? "UsageDock · Token / 额度更新" : "UsageDock · AI 重大更新"
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

