import SwiftUI
import TokenRemainKit
import TokenRemainSyncKit

/// The top-level control restores hidden widgets. Reordering and hiding live in
/// each card's long-press context menu, matching the direct-manipulation model of
/// the Desktop Dock without leaving persistent controls on every card.
struct OverviewLayoutMenu: View {
    let layout: OverviewLayoutStore

    var body: some View {
        Menu {
            if !layout.availableWidgets.isEmpty {
                Section(TRL10n.t("overview.widget.add")) {
                    ForEach(layout.availableWidgets) { widget in
                        Button {
                            withAnimation(.snappy) { layout.show(widget) }
                        } label: {
                            Label(widget.title, systemImage: widget.systemImage)
                        }
                    }
                }
            } else {
                Label(TRL10n.t("overview.widget.all.visible"), systemImage: "checkmark.circle")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TRTheme.text)
                .frame(width: 34, height: 34)
                .background(TRTheme.surface2, in: Circle())
                .overlay { Circle().strokeBorder(TRTheme.border, lineWidth: 1) }
        }
        .accessibilityIdentifier("tr.overview.widgetMenu")
        .accessibilityLabel(TRL10n.t("overview.widget.manage"))
    }

}

/// Native long-press actions for every configurable Overview component. Moving
/// is intentionally a submenu so the first-level menu stays compact and cannot
/// be confused with provider disclosure controls inside the card.
private struct OverviewWidgetContextMenuModifier: ViewModifier {
    let widget: OverviewLayoutStore.Widget
    let layout: OverviewLayoutStore

    func body(content: Content) -> some View {
        content.contextMenu {
            Menu {
                Button {
                    withAnimation(.snappy) { layout.moveUp(widget) }
                } label: {
                    Label(TRL10n.t("overview.widget.move.up"), systemImage: "arrow.up")
                }
                .disabled(!layout.canMoveUp(widget))

                Button {
                    withAnimation(.snappy) { layout.moveDown(widget) }
                } label: {
                    Label(TRL10n.t("overview.widget.move.down"), systemImage: "arrow.down")
                }
                .disabled(!layout.canMoveDown(widget))
            } label: {
                Label(TRL10n.t("overview.widget.move"), systemImage: "arrow.up.arrow.down")
            }

            Divider()

            Button(role: .destructive) {
                withAnimation(.snappy) { layout.hide(widget) }
            } label: {
                Label(TRL10n.t("overview.widget.hide"), systemImage: "eye.slash")
            }
            .disabled(layout.visibleWidgets.count == 1)
        }
    }
}

extension View {
    func overviewWidgetContextMenu(
        widget: OverviewLayoutStore.Widget,
        layout: OverviewLayoutStore
    ) -> some View {
        modifier(OverviewWidgetContextMenuModifier(widget: widget, layout: layout))
    }
}

/// The direct Overview disclosure for a provider. The collapsed state is
/// glanceable; expanding reveals every official window without navigating away.
struct OverviewProviderWidget: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let provider: ProviderQuota.Provider
    let layout: OverviewLayoutStore

    private var windows: [UsageInsights.Window] {
        model.insights.windows(for: provider)
    }

    private var lead: UsageInsights.Window? {
        model.insights.shortestWindow(for: provider)
    }

    private var isExpanded: Bool { layout.isExpanded(provider) }

    var body: some View {
        if let lead {
            PixelCard {
                VStack(alignment: .leading, spacing: 10) {
                    header(lead: lead)
                    SegmentBar(
                        remainingPercent: lead.remainingPercent,
                        accent: TRTheme.accent(for: provider)
                    )
                    .neonGlow(TRTheme.accent(for: provider), intensity: 0.36)

                    TRAdaptiveRow {
                        Text(UsageFormatting.windowName(minutes: lead.windowMinutes))
                            .font(.caption)
                            .foregroundStyle(TRTheme.textDim)
                        Spacer(minLength: 8)
                        Text(resetText(for: lead, now: Date()))
                            .font(.caption)
                            .foregroundStyle(TRTheme.textDim)
                    }

                    if isExpanded {
                        Divider().overlay(TRTheme.border)
                        ForEach(windows) { window in
                            OverviewProviderWindowRow(window: window)
                                .id("overview-\(window.id)")
                            if window.id != windows.last?.id {
                                Divider().overlay(TRTheme.border)
                            }
                        }
                    }
                }
            }
            .cyberCard(border: TRTheme.accentDim(for: provider))
            .trGlassCard(enabled: model.glassEnabled)
        }
    }

    private func header(lead: UsageInsights.Window) -> some View {
        TRAdaptiveRow {
            Button {
                let animation: Animation? = reduceMotion ? nil : .snappy
                withAnimation(animation) { layout.toggleExpanded(provider) }
            } label: {
                HStack(spacing: 8) {
                    ProviderGlyph(provider: provider, size: 19)
                    Text(provider.shortName)
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(TRTheme.text)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TRTheme.textDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tr.overview.provider.toggle.\(provider.rawValue)")
            .accessibilityLabel(
                "\(provider.shortName)，\(UsageFormatting.windowName(minutes: lead.windowMinutes))，\(UsageFormatting.percent(lead.remainingPercent.rounded()))，\(isExpanded ? TRL10n.t("overview.widget.collapse") : TRL10n.t("overview.widget.expand"))"
            )
            .accessibilityHint(TRL10n.t("overview.provider.hint"))

            Spacer(minLength: 8)
            CyberValue(
                UsageFormatting.percent(lead.remainingPercent.rounded()),
                size: 20,
                color: TRTheme.text,
                glow: TRTheme.accent(for: provider)
            )
        }
    }

    private func resetText(for window: UsageInsights.Window, now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return TRL10n.t("limits.reset.unknown") }
        return UsageFormatting.resetDescription(to: resetsAt, now: now)
    }
}

/// A dense, full-detail quota row used by the expanded Overview disclosure.
/// It does not make a second provider fetch: every number derives from the same
/// snapshot already rendered in the card header.
struct OverviewProviderWindowRow: View {
    @Environment(AppModel.self) private var model

    let window: UsageInsights.Window

    private var accent: Color { TRTheme.accent(for: window.provider) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let pace = model.insights.pace(for: window, at: context.date)
            VStack(alignment: .leading, spacing: 8) {
                TRAdaptiveRow {
                    Text(UsageFormatting.windowName(minutes: window.windowMinutes))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(TRTheme.text)
                    Spacer(minLength: 8)
                    Text(UsageFormatting.percent(window.remainingPercent.rounded()))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(TRTheme.text)
                }

                SegmentBar(remainingPercent: window.remainingPercent, accent: accent)

                TRAdaptiveRow {
                    Label(resetDescription(now: context.date), systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                    Spacer(minLength: 8)
                    if let pace {
                        PixelBadge(paceLabel(pace.status), accent: paceAccent(pace.status))
                    }
                }

                if let pace {
                    TRAdaptiveRow(spacing: 6) {
                        miniMetric(TRL10n.t("limits.pace.expected"), UsageFormatting.percent(pace.expectedUsedPercent.rounded()))
                        miniMetric(TRL10n.t("limits.pace.actual"), UsageFormatting.percent(pace.actualUsedPercent.rounded()))
                        miniMetric(TRL10n.t("limits.pace.delta"), signed(pace.deltaPercent))
                    }
                    if let runOut = pace.estimatedRunOutAt {
                        Label(
                            TRL10n.f("limits.pace.projected", UsageFormatting.durationUntil(runOut, now: context.date)),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(TRTheme.warning)
                    }
                } else {
                    Text(TRL10n.t("limits.pace.unavailable"))
                        .font(.caption)
                        .foregroundStyle(TRTheme.textMute)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("tr.overview.window.\(window.id)")
            .accessibilityLabel(accessibilityLabel(pace: pace, now: context.date))
        }
    }

    private func miniMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(TRTheme.textDim)
            Text(value)
                .font(.system(.caption, design: .monospaced).monospacedDigit())
                .foregroundStyle(TRTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetDescription(now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return TRL10n.t("limits.reset.unknown") }
        return UsageFormatting.resetDescription(to: resetsAt, now: now)
    }

    private func signed(_ value: Double) -> String {
        (value > 0 ? "+" : "") + UsageFormatting.percent(value.rounded())
    }

    private func paceLabel(_ status: UsagePace.Status) -> String {
        switch status {
        case .onTrack: return TRL10n.t("limits.pace.status.ontrack")
        case .reserve: return TRL10n.t("limits.pace.status.reserve")
        case .deficit: return TRL10n.t("limits.pace.status.deficit")
        }
    }

    private func paceAccent(_ status: UsagePace.Status) -> Color {
        switch status {
        case .onTrack: return TRTheme.indigo
        case .reserve: return TRTheme.success
        case .deficit: return TRTheme.warning
        }
    }

    private func accessibilityLabel(pace: UsagePace?, now: Date) -> String {
        var parts = [
            UsageFormatting.windowName(minutes: window.windowMinutes),
            "\(TRL10n.t("overview.min_remaining")) \(UsageFormatting.percent(window.remainingPercent.rounded()))",
            resetDescription(now: now)
        ]
        if let pace {
            parts.append(paceLabel(pace.status))
            if let runOut = pace.estimatedRunOutAt {
                parts.append(TRL10n.f("limits.pace.projected", UsageFormatting.durationUntil(runOut, now: now)))
            }
        }
        return parts.joined(separator: "，")
    }
}

/// Displays only real, bounded public posts previously curated by the Mac. An
/// empty feed is explicit: iPhone never invents posts or contacts X directly.
struct CuratedFeedWidget: View {
    let feed: SyncedCuratedFeed?

    private var posts: [SyncedCuratedPost] {
        Array((feed?.posts ?? []).prefix(SyncedCuratedFeed.maximumPosts))
    }

    var body: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 10) {
                TRAdaptiveRow {
                    Label(TRL10n.t("overview.feed.title"), systemImage: "bubble.left.and.bubble.right")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(TRTheme.text)
                }

                if posts.isEmpty {
                    Label(TRL10n.t("overview.feed.empty"), systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(TRTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tr.overview.feed.empty")
                } else {
                    ForEach(posts) { post in
                        if post.id != posts.first?.id { Divider().overlay(TRTheme.border) }
                        Link(destination: post.url) {
                            postRow(post)
                        }
                        .accessibilityIdentifier("tr.overview.feed.post.\(post.id)")
                        .accessibilityLabel("\(post.displayName)：\(post.text)")
                        .accessibilityHint(TRL10n.t("overview.feed.open.hint"))
                    }
                    if let capturedAt = feed?.capturedAt {
                        Text(TRL10n.f("overview.feed.freshness", UsageFormatting.freshnessDescription(since: capturedAt, now: Date())))
                            .font(.caption2)
                            .foregroundStyle(TRTheme.textMute)
                    }
                }
            }
        }
        .cyberCard()
    }

    private func postRow(_ post: SyncedCuratedPost) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(priorityColor(post.priority))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                TRAdaptiveRow(spacing: 5) {
                    Text(post.displayName)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(TRTheme.text)
                    Text("@\(post.username)")
                        .font(.caption2)
                        .foregroundStyle(TRTheme.textMute)
                    Spacer(minLength: 6)
                    Text(post.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(TRTheme.textMute)
                }
                Text(post.text)
                    .font(.footnote)
                    .foregroundStyle(TRTheme.textDim)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TRTheme.textMute)
                .padding(.top, 3)
        }
        .contentShape(Rectangle())
    }

    private func priorityColor(_ priority: SyncedCuratedPost.Priority) -> Color {
        switch priority {
        case .tokenReset: return TRTheme.warning
        case .majorUpdate: return TRTheme.indigo
        case .normal: return TRTheme.textMute
        }
    }
}
