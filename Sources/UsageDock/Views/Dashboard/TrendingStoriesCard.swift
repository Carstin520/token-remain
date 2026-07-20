import AppKit
import SwiftUI

/// The one or two posts worth reading right now, taken verbatim from
/// `feedStore.topStories`.
///
/// Ranking is frozen upstream; this view only decides how loudly to say
/// "this is the most trending thing". Rank 1 gets a warm ember accent and a
/// visible glow, rank 2 a quieter purple — no other chrome in the card borrows
/// these colors, so the accent always means rank.
struct TrendingStoriesCard: View {
    let posts: [AIFeedPost]

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(title: "Trending", subtitle: "此刻最值得关注") {
                    TagPill(text: "HOT", color: TrendingRank.first.accent, background: DashboardTheme.surface2)
                }

                if posts.isEmpty {
                    Text("正在捕捉热门动态…")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(posts.prefix(2).enumerated()), id: \.element.id) { index, post in
                        TrendingStoryRow(post: post, rank: TrendingRank(index: index))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        self == .first ? DashboardTheme.cyan : DashboardTheme.violet
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

    var body: some View {
        Button {
            NSWorkspace.shared.open(post.postURL)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: rank.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(rank.accent)
                    Text(rank.label)
                        .numericFont(10, .heavy)
                        .foregroundStyle(rank.accent)

                    Text(post.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                        .lineLimit(1)

                    Text(post.createdAt, style: .relative)
                        .numericFont(9)
                        .foregroundStyle(DashboardTheme.mutedText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DashboardTheme.mutedText)
                }

                Text(post.text)
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    metric("bubble.left", post.metrics.replies)
                    metric("arrow.2.squarepath", post.metrics.reposts)
                    metric("heart", post.metrics.likes)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(rank.accent.opacity(rank.backgroundOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(rank.accent.opacity(rank.borderOpacity), lineWidth: 1)
            )
            .shadow(color: rank.accent.opacity(rank.glowRadius > 0 ? 0.28 : 0), radius: rank.glowRadius)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("热门第 \(rank == .first ? 1 : 2) 条，\(post.displayName)：\(post.text)")
        .accessibilityHint("在 X 打开原帖")
    }

    private func metric(_ icon: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(UsageFormatting.compactNumber(Int64(value)))
                .numericFont(9, .medium)
        }
        .foregroundStyle(DashboardTheme.mutedText)
    }
}
