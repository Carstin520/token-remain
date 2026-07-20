import SwiftUI
import UserNotifications

struct AIFeedSection: View {
    @ObservedObject var store: AIFeedStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: "AI Feed",
                subtitle: "与你的额度和工作流直接相关的精选更新",
                trailing: updatedText
            )

            notificationCard

            if store.errorMessage != nil {
                updateUnavailableCard
            }

            if !store.importantPosts.isEmpty {
                feedGroup(
                    title: "重要提醒",
                    subtitle: "额度、价格、产品发布和服务状态优先",
                    posts: store.importantPosts
                )
            }

            if store.posts.isEmpty && store.errorMessage == nil {
                DashboardCard {
                    EmptyStateView(
                        icon: "dot.radiowaves.left.and.right",
                        title: store.isRefreshing ? "正在同步精选动态" : "暂无重要动态",
                        message: store.isRefreshing
                            ? "正在筛选与你的额度和工作流直接相关的信息。"
                            : "有值得关注的新消息时会自动出现在这里。"
                    )
                }
            }

            if !store.morePosts.isEmpty {
                feedGroup(
                    title: "更多值得关注",
                    subtitle: "按相关性、时效和互动质量排序",
                    posts: store.morePosts
                )
            }
        }
        .onAppear { store.start() }
    }

    private var updatedText: String? {
        store.lastUpdated.map {
            "更新于 " + $0.formatted(date: .omitted, time: .standard)
        }
    }

    private var notificationCard: some View {
        DashboardCard {
            HStack(spacing: 12) {
                Image(systemName: notificationIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(notificationColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("重要动态提醒")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                    Text(notificationText)
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.secondaryText)
                }

                Spacer()

                if store.notificationsEnabled && store.notificationStatus == .notDetermined {
                    Button("允许通知") {
                        Task { await store.requestNotificationPermission() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                }

                Toggle(
                    "通知",
                    isOn: Binding(
                        get: { store.notificationsEnabled },
                        set: { value in Task { await store.setNotificationsEnabled(value) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DashboardTheme.violet)
                .accessibilityLabel("重要动态通知")
            }
        }
    }

    private var updateUnavailableCard: some View {
        DashboardCard {
            Label(
                "精选动态暂时无法更新，应用会在后台自动重试。",
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
        guard store.notificationsEnabled else { return "通知已关闭" }
        switch store.notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return "额度重置和重大更新会通过系统通知提醒"
        case .denied:
            return "通知已被系统拒绝，请到系统设置中开启"
        case .notDetermined:
            return "允许通知后，重要变化会第一时间提醒"
        @unknown default:
            return "通知状态未知"
        }
    }

    private var notificationIcon: String {
        store.notificationStatus == .denied ? "bell.slash.fill" : "bell.badge.fill"
    }

    private var notificationColor: Color {
        store.notificationStatus == .denied ? DashboardTheme.warning : DashboardTheme.success
    }
}
