import SwiftUI
import TokenRemainKit
import WidgetKit

/// Read-only over the watch's own App Group container, written by the watch app
/// when it receives an `applicationContext` from the iPhone.
struct WatchTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TREntry {
        TREntry.placeholder(now: SnapshotComposer.previewNow)
    }

    func getSnapshot(in context: Context, completion: @escaping (TREntry) -> Void) {
        let now = Date()
        completion(context.isPreview
            ? TREntry.placeholder(now: now)
            : TREntry(snapshot: SnapshotStore.shared.readOrEmpty(now: now), now: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TREntry>) -> Void) {
        let now = Date()
        let entry = TREntry(snapshot: SnapshotStore.shared.readOrEmpty(now: now), now: now)
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

private extension View {
    func trWatchContainer() -> some View {
        containerBackground(TRTheme.ink, for: .widget)
    }
}

// MARK: - accessoryCircular · Activity-ring double gauge

/// The face-addable complication the user asked for: two concentric Activity-style
/// rings — outer = Claude remaining (violet), inner = Codex remaining (cyan) — with
/// the minimum-remaining % in the centre. The rings encode *remaining* fraction and
/// keep the slot meter colours (identity, not status); their different radii keep
/// them legible in the watch-face vibrant rendering mode where colour flattens.
struct TRWatchRemainGauge: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRWatchRemainGauge", provider: WatchTimelineProvider()) { entry in
            Group {
                if entry.hasNumbers {
                    // Meters carry the muted provider accents (terracotta / steel
                    // blue) — brand colour stays on logos, per the desktop rule.
                    ActivityRings(
                        outerRemaining: entry.remainingPercent(for: .claude) ?? entry.minRemainingPercent ?? 0,
                        innerRemaining: entry.remainingPercent(for: .codex) ?? entry.minRemainingPercent ?? 0,
                        outerColor: TRTheme.claudeAccent,
                        innerColor: TRTheme.codexAccent,
                        lineWidth: nil,
                        centerLabel: entry.heroText
                    )
                    .padding(1)
                } else {
                    ZStack {
                        AccessoryWidgetBackground()
                        PixelRobot(remainingPercent: 0, size: 26, monochrome: true)
                            .accessibilityHidden(true)
                    }
                }
            }
            .trWatchContainer()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.watchAccessibilityLabel)
        }
        .configurationDisplayName(TRL10n.t("widget.name.rings"))
        .description(TRL10n.t("widget.desc.rings"))
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - accessoryCircular · reset countdown

struct TRWatchResetCountdown: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRWatchResetCountdown", provider: WatchTimelineProvider()) { entry in
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    if let reset = entry.soonestReset {
                        Text(reset, style: .timer)
                            .font(.system(size: 12, design: .monospaced).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(TRL10n.t("overview.reset.card"))
                            .font(.system(size: 8, design: .monospaced))
                    } else {
                        Text("—").font(.system(size: 14, design: .monospaced))
                    }
                }
                .padding(3)
            }
            .trWatchContainer()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.watchAccessibilityLabel)
        }
        .configurationDisplayName(TRL10n.t("widget.name.reset"))
        .description(TRL10n.t("widget.desc.reset"))
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - accessoryCircular · status robot

struct TRWatchStatusRobot: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRWatchStatusRobot", provider: WatchTimelineProvider()) { entry in
            ZStack {
                AccessoryWidgetBackground()
                PixelRobot(remainingPercent: entry.minRemainingPercent, size: 30, monochrome: true)
                    .accessibilityHidden(true)
            }
            .trWatchContainer()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.watchAccessibilityLabel)
        }
        .configurationDisplayName("TokenRemain")
        .description(TRL10n.t("widget.desc.status"))
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - accessoryCorner

struct TRWatchCorner: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRWatchCorner", provider: WatchTimelineProvider()) { entry in
            // Corner content = a miniature dual-arc AI mark (both platforms, brand
            // colours, robot centre); the curved bezel label carries "AI 用量 · 最低 46%".
            Group {
                if entry.hasNumbers {
                    MiniDualArc(
                        outerRemaining: entry.remainingPercent(for: .claude) ?? entry.minRemainingPercent ?? 0,
                        innerRemaining: entry.remainingPercent(for: .codex) ?? entry.minRemainingPercent ?? 0,
                        size: 26
                    )
                    .widgetLabel {
                        Text("\(TRL10n.t("mark.ai_usage")) · \(TRL10n.t("overview.min_remaining")) \(entry.heroText)")
                            .font(.system(.caption2, design: .monospaced).monospacedDigit())
                    }
                } else {
                    RobotHeadGlyph(size: 22, color: TRTheme.textDim)
                        .widgetLabel { Text(TRL10n.t("origin.none.status")) }
                }
            }
            .trWatchContainer()
            .accessibilityLabel(entry.watchAccessibilityLabel)
        }
        .configurationDisplayName(TRL10n.t("widget.name.corner"))
        .description(TRL10n.t("widget.desc.corner"))
        .supportedFamilies([.accessoryCorner])
    }
}

// MARK: - accessoryRectangular · Smart Stack card

struct TRWatchRectangular: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRWatchRectangular", provider: WatchTimelineProvider()) { entry in
            Group {
                if entry.hasNumbers {
                    HStack(spacing: 7) {
                        PixelRobot(remainingPercent: entry.minRemainingPercent, size: 24, monochrome: true)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                // Provider indicator: the glyph of the constraining source.
                                if let provider = entry.constrainingProvider {
                                    ProviderGlyph(provider: provider, size: 10)
                                }
                                Text(TRL10n.t("overview.min_remaining"))
                                    .font(.system(size: 9, design: .monospaced))
                                Spacer()
                                if entry.isDemo {
                                    Text("D̸").font(.system(size: 8, design: .monospaced))
                                }
                                if entry.isStale {
                                    Text(TRL10n.t("liveactivity.stale"))
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(TRTheme.textDim)
                                }
                            }
                            HStack(spacing: 4) {
                                Text(entry.heroText)
                                    .font(.system(size: 16, design: .monospaced).monospacedDigit().weight(.semibold))
                                Text(TRL10n.t("risk.short.\(entry.risk.rawValue)") + entry.risk.glyph)
                                    .font(.system(size: 9, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(TRTheme.riskSemantic(entry.risk))
                            }
                            HStack(spacing: 3) {
                                PixelCheck(entry.willLastUntilReset ? .checked : .warn, size: 8,
                                           accent: TRTheme.riskSemantic(entry.risk))
                                Text(entry.willLastUntilReset ? TRL10n.t("pace.short.ok") : TRL10n.t("pace.short.early"))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TRTheme.riskSemantic(entry.risk))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            if let reset = entry.soonestReset {
                                Text(TRL10n.f("reset.countdown", UsageFormatting.shortCountdown(to: reset, now: entry.date)))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(TRTheme.textDim)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        PixelRobot(remainingPercent: 0, size: 22, monochrome: true)
                            .accessibilityHidden(true)
                        Text(TRL10n.t("watch.waiting"))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .trWatchContainer()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.watchAccessibilityLabel)
        }
        .configurationDisplayName("TokenRemain")
        .description(TRL10n.t("widget.desc.min"))
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - accessoryInline

struct TRWatchInline: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TRWatchInline", provider: WatchTimelineProvider()) { entry in
            // "AI 46% · 可持续到重置" — AI-usage marker, min %, pace verdict.
            Text(entry.hasNumbers
                ? "AI \(entry.isDemo ? "D̸ " : "")\(entry.heroText) · \(entry.paceLine)"
                    + (entry.isStale ? " · \(TRL10n.t("liveactivity.stale"))" : "")
                : TRL10n.t("origin.none.status"))
                .trWatchContainer()
                .accessibilityLabel(entry.watchAccessibilityLabel)
        }
        .configurationDisplayName(TRL10n.t("widget.name.inline"))
        .description(TRL10n.t("widget.desc.min"))
        .supportedFamilies([.accessoryInline])
    }
}

extension TREntry {
    var watchAccessibilityLabel: String {
        guard hasNumbers else {
            return isExpired ? TRL10n.t("origin.macsync.expired") : TRL10n.t("watch.waiting")
        }
        var parts = ["\(TRL10n.t("overview.min_remaining")) \(heroText)", paceLine]
        parts.append(TRL10n.f("watch.provenance", UsageFormatting.freshnessDescription(since: generatedAt, now: date)))
        if isDemo { parts.append(TRL10n.t("demo.a11y")) }
        if isStale { parts.append(TRL10n.t("liveactivity.stale")) }
        return parts.joined(separator: "，")
    }
}

@main
struct TokenRemainWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        TRWatchRemainGauge()
        TRWatchResetCountdown()
        TRWatchStatusRobot()
        TRWatchCorner()
        TRWatchRectangular()
        TRWatchInline()
    }
}
