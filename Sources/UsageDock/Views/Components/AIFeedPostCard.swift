import AppKit
import SwiftUI

struct AIFeedPostCard: View {
    let post: AIFeedPost
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dashboardSurfaces) private var surfaces
    @State private var isHovering = false

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
                    Text(L10n.text("feed.view_on_x"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DashboardTheme.link)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            // AI Feed cards own their chrome instead of going through the
            // system glass compositor. That keeps the priority edge above the
            // card surface, so cyan/violet cannot be washed out by Liquid
            // Glass or the desktop behind the window.
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(cardFillColor)
                    .shadow(
                        color: perimeterGlowColor,
                        radius: isHovering ? 9 : 5
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(cardBorderColor, lineWidth: cardBorderWidth)
            }
            .overlay(alignment: .leading) {
                if post.priority != .normal {
                    Capsule()
                        .fill(priorityAccent.opacity(0.82))
                        .frame(width: 3, height: 38)
                        .padding(.leading, 5)
                        .accessibilityHidden(true)
                }
            }
            .pixelTicks(
                cornerRadius: 13,
                color: post.priority == .normal
                    ? surfaces.border
                    : priorityAccent.opacity(0.76)
            )
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: 0.16),
                value: isHovering
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(L10n.format("feed.post_accessibility", post.displayName, post.text))
        .accessibilityHint(L10n.text("feed.open_x_hint"))
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

    private var cardBorderColor: Color {
        post.priority == .normal
            ? surfaces.border
            : priorityAccent.opacity(0.80)
    }

    private var cardBorderWidth: CGFloat {
        post.priority == .normal ? 1 : 1.5
    }

    private var cardFillColor: Color {
        isHovering ? surfaces.surface2 : surfaces.surface
    }

    private var perimeterGlowColor: Color {
        guard post.priority != .normal else { return .clear }
        return priorityAccent.opacity(isHovering ? 0.20 : 0.11)
    }

    private var priorityAccent: Color {
        DashboardTheme.feedAccent(for: post.priority)
    }

    private var priorityBadge: some View {
        Label(post.priority.title, systemImage: post.priority == .tokenReset ? "gauge.with.dots.needle.67percent" : "bolt.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(priorityAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(DashboardSurface.surface3.opacity(0.9), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(priorityAccent.opacity(0.52), lineWidth: 1)
            }
    }

    private func metric(icon: String, value: Int) -> some View {
        Label(UsageFormatting.compactNumber(Int64(value)), systemImage: icon)
            .numericFont(10)
            .foregroundStyle(DashboardTheme.secondaryText)
    }
}
