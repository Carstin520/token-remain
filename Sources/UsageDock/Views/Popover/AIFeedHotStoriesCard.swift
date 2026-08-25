import AppKit
import SwiftUI

struct AIFeedHotStoriesCard: View {
    let posts: [AIFeedPost]
    let isExpanded: Bool
    @ObservedObject var layout: PopoverLayoutStore
    let onViewAll: () -> Void

    var body: some View {
        DashboardCard(padding: 13, cornerRadius: 13, interactive: true) {
            VStack(alignment: .leading, spacing: 10) {
                PopoverWidgetHeader(
                    widget: .aiFeed,
                    isExpanded: isExpanded,
                    isPinned: layout.isPinned(.aiFeed),
                    onToggleExpanded: { withAnimation(.snappy) { layout.toggleExpanded(.aiFeed) } },
                    onTogglePinned: { layout.togglePinned(.aiFeed) },
                    onHide: { withAnimation(.snappy) { layout.hide(.aiFeed) } },
                    onMoveUp: { layout.moveUp(.aiFeed) },
                    onMoveDown: { layout.moveDown(.aiFeed) }
                ) {
                    Text(posts.isEmpty
                        ? L10n.text("feed.updating")
                        : L10n.format("feed.item_count", min(2, posts.count)))
                        .font(.system(size: 10, weight: .semibold))
                        .usageDockAdaptiveForeground(.secondary)
                }

                HStack {
                    Text(posts.isEmpty
                        ? L10n.text("feed.filtering")
                        : (isExpanded ? L10n.text("feed.full_top_stories") : L10n.text("feed.important_updates")))
                        .font(.system(size: 10))
                        .usageDockAdaptiveForeground(.secondary)
                    Spacer()
                    Button(L10n.text("feed.view_all"), action: onViewAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .usageDockAdaptiveForeground(.secondary)
                }

                if !posts.isEmpty {
                    ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                        if index > 0 {
                            Divider().overlay(DashboardSurface.border)
                        }
                        storyRow(post, showsFullText: isExpanded)
                    }
                }
            }
        }
    }

    private func storyRow(_ post: AIFeedPost, showsFullText: Bool) -> some View {
        Button {
            NSWorkspace.shared.open(post.postURL)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(DashboardTheme.feedAccent(for: post.priority))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(post.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .usageDockAdaptiveForeground(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(post.createdAt, style: .relative)
                            .numericFont(9)
                            .usageDockAdaptiveForeground(.muted)
                            .lineLimit(1)
                    }
                    Text(showsFullText ? normalizedText(post.text) : shortHeadline(post.text))
                        .font(.system(size: 11, weight: .medium))
                        .usageDockAdaptiveForeground(.secondary)
                        .lineLimit(showsFullText ? nil : 1)
                        .fixedSize(horizontal: false, vertical: showsFullText)
                        .animation(.snappy(duration: 0.22), value: showsFullText)
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .usageDockAdaptiveForeground(.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("feed.post_accessibility", post.displayName, post.text))
        .accessibilityHint(L10n.text("feed.open_x_hint"))
    }

    private func shortHeadline(_ text: String) -> String {
        let compact = normalizedText(text)
        guard compact.count > 30 else { return compact }
        return String(compact.prefix(29)) + "…"
    }

    private func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

}
