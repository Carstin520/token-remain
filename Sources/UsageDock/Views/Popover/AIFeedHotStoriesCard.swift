import AppKit
import SwiftUI

struct AIFeedHotStoriesCard: View {
    let posts: [AIFeedPost]
    let isExpanded: Bool
    @ObservedObject var layout: PopoverLayoutStore
    @Binding var draggingWidget: PopoverWidget?
    let onViewAll: () -> Void

    var body: some View {
        DashboardCard(padding: 13, cornerRadius: 13) {
            VStack(alignment: .leading, spacing: 10) {
                PopoverWidgetHeader(
                    widget: .aiFeed,
                    isExpanded: isExpanded,
                    isPinned: layout.isPinned(.aiFeed),
                    draggingWidget: $draggingWidget,
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
                        .foregroundStyle(DashboardTheme.secondaryText)
                }

                HStack {
                    Text(posts.isEmpty
                        ? L10n.text("feed.filtering")
                        : (isExpanded ? L10n.text("feed.full_top_stories") : L10n.text("feed.important_updates")))
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.secondaryText)
                    Spacer()
                    Button(L10n.text("feed.view_all"), action: onViewAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DashboardTheme.link)
                }

                if !posts.isEmpty {
                    ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                        if index > 0 {
                            Divider().overlay(DashboardTheme.border)
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
                    .fill(accentColor(for: post))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(post.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DashboardTheme.text)
                        Text(post.createdAt, style: .relative)
                            .numericFont(9)
                            .foregroundStyle(DashboardTheme.mutedText)
                    }
                    Text(showsFullText ? normalizedText(post.text) : shortHeadline(post.text))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .lineLimit(showsFullText ? nil : 1)
                        .fixedSize(horizontal: false, vertical: showsFullText)
                        .animation(.snappy(duration: 0.22), value: showsFullText)
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DashboardTheme.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(post.displayName)：\(post.text)")
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

    private func accentColor(for post: AIFeedPost) -> Color {
        switch post.priority {
        case .tokenReset: return DashboardTheme.warning
        case .majorUpdate: return DashboardTheme.purple
        case .normal: return DashboardTheme.codex
        }
    }
}
