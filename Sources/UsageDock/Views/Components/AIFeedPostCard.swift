import AppKit
import SwiftUI

struct AIFeedPostCard: View {
    let post: AIFeedPost

    var body: some View {
        Button {
            NSWorkspace.shared.open(post.postURL)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 11) {
                    avatar

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(post.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DashboardTheme.text)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text("@\(post.username)")
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardTheme.mutedText)
                                .lineLimit(1)
                        }
                        Text(post.createdAt, style: .relative)
                            .numericFont(10)
                            .foregroundStyle(DashboardTheme.mutedText)
                    }

                    Spacer(minLength: 8)

                    if post.priority != .normal {
                        priorityBadge
                    }

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DashboardTheme.mutedText)
                }

                Text(post.text)
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.text)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    metric(icon: "bubble.left", value: post.metrics.replies)
                    metric(icon: "arrow.2.squarepath", value: post.metrics.reposts)
                    metric(icon: "heart", value: post.metrics.likes)
                    Spacer()
                    Text("在 X 查看")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DashboardTheme.link)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .usageDockGlassSurface(
                cornerRadius: 13,
                tint: glassTint,
                interactive: true,
                fallbackBackground: DashboardTheme.surface,
                fallbackBorder: borderColor
            )
            .pixelTicks(cornerRadius: 13)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(post.displayName)：\(post.text)")
        .accessibilityHint("在 X 打开原帖")
    }

    private var avatar: some View {
        Circle()
            .fill(avatarColor.opacity(0.18))
            .frame(width: 34, height: 34)
            .overlay(
                Text(post.initials)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(avatarColor)
            )
    }

    private var avatarColor: Color {
        switch post.username.lowercased() {
        case "claudeai", "anthropicai": return DashboardTheme.claude
        case "openai", "sama": return DashboardTheme.codex
        default: return DashboardTheme.purple
        }
    }

    private var borderColor: Color {
        switch post.priority {
        case .tokenReset: return DashboardTheme.warning.opacity(0.8)
        case .majorUpdate: return DashboardTheme.purple.opacity(0.8)
        case .normal: return DashboardTheme.border
        }
    }

    private var glassTint: Color? {
        switch post.priority {
        case .tokenReset: return DashboardTheme.warning.opacity(0.16)
        case .majorUpdate: return DashboardTheme.purple.opacity(0.16)
        case .normal: return nil
        }
    }

    private var priorityBadge: some View {
        Label(post.priority.title, systemImage: post.priority == .tokenReset ? "gauge.with.dots.needle.67percent" : "bolt.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(post.priority == .tokenReset ? DashboardTheme.warning : DashboardTheme.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                (post.priority == .tokenReset ? DashboardTheme.warning : DashboardTheme.purple).opacity(0.12),
                in: Capsule()
            )
    }

    private func metric(icon: String, value: Int) -> some View {
        Label(UsageFormatting.compactNumber(Int64(value)), systemImage: icon)
            .numericFont(10)
            .foregroundStyle(DashboardTheme.secondaryText)
    }
}
