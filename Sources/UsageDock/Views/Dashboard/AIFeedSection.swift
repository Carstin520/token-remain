import SwiftUI
import UserNotifications

struct AIFeedSection: View {
    @ObservedObject var store: AIFeedStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: "AI Feed",
                subtitle: L10n.text("feed.section_subtitle"),
                trailing: updatedText
            )

            notificationCard

            if store.errorMessage != nil {
                updateUnavailableCard
            }

            if !store.importantPosts.isEmpty {
                feedGroup(
                    title: L10n.text("feed.important_title"),
                    subtitle: L10n.text("feed.important_subtitle"),
                    posts: store.importantPosts
                )
            }

            if store.posts.isEmpty && store.errorMessage == nil {
                DashboardCard {
                    EmptyStateView(
                        icon: "dot.radiowaves.left.and.right",
                        title: store.isRefreshing ? L10n.text("feed.syncing_title") : L10n.text("feed.empty_title"),
                        message: store.isRefreshing
                            ? L10n.text("feed.syncing_message")
                            : L10n.text("feed.empty_message")
                    )
                }
            }

            if !store.morePosts.isEmpty {
                feedGroup(
                    title: L10n.text("feed.more_title"),
                    subtitle: L10n.text("feed.more_subtitle"),
                    posts: store.morePosts
                )
            }
        }
        .onAppear { store.start() }
    }

    private var updatedText: String? {
        store.lastUpdated.map {
            L10n.format("common.updated_at", $0.formatted(date: .omitted, time: .standard))
        }
    }

    private var notificationCard: some View {
        DashboardCard {
            HStack(spacing: 12) {
                Image(systemName: notificationIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(notificationColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("feed.notify_title"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                    Text(notificationText)
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.secondaryText)
                }

                Spacer()

                if store.notificationsEnabled && store.notificationStatus == .notDetermined {
                    Button(L10n.text("feed.allow_notifications")) {
                        Task { await store.requestNotificationPermission() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                }

                Toggle(
                    L10n.text("feed.notifications"),
                    isOn: Binding(
                        get: { store.notificationsEnabled },
                        set: { value in Task { await store.setNotificationsEnabled(value) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DashboardTheme.violet)
                .accessibilityLabel(L10n.text("feed.notify_accessibility"))
            }
        }
    }

    private var updateUnavailableCard: some View {
        DashboardCard {
            Label(
                L10n.text("feed.update_unavailable"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feedGroup(title: String, subtitle: String, posts: [AIFeedPost]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: title, subtitle: subtitle)
            LazyVStack(spacing: 10) {
                ForEach(posts) { post in
                    AIFeedPostCard(post: post)
                }
            }
        }
    }

    private var notificationText: String {
        guard store.notificationsEnabled else { return L10n.text("feed.notify_off") }
        switch store.notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return L10n.text("feed.notify_on_desc")
        case .denied:
            return L10n.text("feed.notify_denied")
        case .notDetermined:
            return L10n.text("feed.notify_prompt")
        @unknown default:
            return L10n.text("feed.notify_unknown")
        }
    }

    private var notificationIcon: String {
        store.notificationStatus == .denied ? "bell.slash.fill" : "bell.badge.fill"
    }

    private var notificationColor: Color {
        store.notificationStatus == .denied ? DashboardTheme.warning : DashboardTheme.success
    }
}
