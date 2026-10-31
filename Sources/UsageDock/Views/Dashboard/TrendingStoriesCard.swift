import AppKit
import SwiftUI

/// The one or two posts worth reading right now, taken verbatim from
/// `feedStore.topStories`.
///
/// Ranking is frozen upstream; this view only decides how loudly to say
/// "this is the most trending thing". Rank 1 gets an informational cyan accent
/// and visible glow, while rank 2 uses a quieter violet. Priority-specific feed
/// semantics can override rank hue without changing the rank label or strength.
struct TrendingStoriesCard: View {
    let posts: [AIFeedPost]
    /// The Overview's minute timeline; post ages advance with it.
    var now: Date = .now
    @Environment(\.overviewPanelFillsHeight) private var fillsHeight

    /// Beside the usage card the row is taller, so each post gets four lines
    /// of text instead of two. A fixed limit, not a fit-to-height search: a
    /// layout that tried several limits re-measured every post on each
    /// window layout pass and kept Overview busy at ~24% CPU while idle.
    static let fillLineLimit = 4

    var body: some View {
        OverviewPanelCard(contentSpacing: 8, scrollsContent: false) {
            PanelHeader(title: "Trending", subtitle: L10n.text("feed.trending_subtitle")) {
                TagPill(text: "HOT", color: TrendingRank.first.accent, background: DashboardTheme.surface2)
            }
        } content: {
            if posts.isEmpty {
                Text(L10n.text("feed.trending_loading"))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                rows(lineLimit: fillsHeight ? Self.fillLineLimit : 2)
            }
        }
    }

    /// A post's age in the system's short units (`1 day, 1 hr`). Plain text
    /// advanced by the Overview's minute timeline: a live relative-date Text
    /// ticks every second, and on Overview each tick re-lays out the page.
    static func age(of date: Date, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: max(60, now.timeIntervalSince(date))) ?? ""
    }

    /// Paragraph breaks become line breaks, so a blank line never takes one
    /// of the few lines the card has. The accessibility label keeps the post
    /// verbatim.
    static func compactText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n[ \\t]*(\\n[ \\t]*)+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rows(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(posts.prefix(2).enumerated()), id: \.element.id) { index, post in
                TrendingStoryRow(post: post, rank: TrendingRank(index: index), lineLimit: lineLimit, now: now)
            }
        }
    }
}

/// Rank-specific accent treatment. Kept separate so rank 1 stays unambiguously
/// hotter than rank 2 at every layer (symbol, border, glow).
enum TrendingRank {
    case first
    case second

    init(index: Int) {
        self = index == 0 ? .first : .second
    }

    var label: String {
        self == .first ? "#1" : "#2"
    }

    var symbol: String {
        self == .first ? "flame.fill" : "bolt.fill"
    }

    var accent: Color {
        // Kept within the three-color system: rank 1 = cyan (attention),
        // rank 2 = violet. Rank still reads unambiguously via glyph + label.
        self == .first ? DashboardTheme.information : DashboardTheme.violet
    }

    var backgroundOpacity: Double {
        self == .first ? 0.13 : 0.08
    }

    var borderOpacity: Double {
        self == .first ? 0.55 : 0.30
    }

    var glowRadius: CGFloat {
        self == .first ? 9 : 0
    }
}

/// A whole trending post as a single click target opening the original tweet.
private struct TrendingStoryRow: View {
    let post: AIFeedPost
    let rank: TrendingRank
    let lineLimit: Int
    let now: Date

    private var accent: Color {
        post.priority == .normal
            ? rank.accent
            : DashboardTheme.feedAccent(for: post.priority)
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(post.postURL)
        } label: {
            content
        }
        .buttonStyle(PressRippleButtonStyle(cornerRadius: 11, pressedScale: 0.985, rippleOpacity: 0.12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("feed.trending_accessibility", rank == .first ? 1 : 2, post.displayName, post.text))
        .accessibilityHint(L10n.text("feed.open_x_hint"))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: rank.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                Text(rank.label)
                    .numericFont(11, .heavy)
                    .foregroundStyle(accent)

                Text(post.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)

                Text(TrendingStoriesCard.age(of: post.createdAt, now: now))
                    .numericFont(11)
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DashboardTheme.mutedText)
            }

            Text(TrendingStoriesCard.compactText(post.text))
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                metric("bubble.left", post.metrics.replies)
                metric("arrow.2.squarepath", post.metrics.reposts)
                metric("heart", post.metrics.likes)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(accent.opacity(rank.backgroundOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(accent.opacity(rank.borderOpacity), lineWidth: 1)
        )
        .shadow(color: accent.opacity(rank.glowRadius > 0 ? 0.28 : 0), radius: rank.glowRadius)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func metric(_ icon: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(UsageFormatting.compactNumber(Int64(value)))
                .numericFont(11, .medium)
        }
        .foregroundStyle(DashboardTheme.mutedText)
    }
}
