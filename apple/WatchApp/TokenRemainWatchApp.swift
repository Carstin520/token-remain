import SwiftUI
import TokenRemainKit

@main
struct TokenRemainWatchApp: App {
    @State private var receiver: WatchSnapshotReceiver

    init() {
        // Simulator / screenshot seam: `-tr-demo <scenario>` (or `-tr-origin-none`)
        // seeds the watch's own App Group store *before* the receiver reads it, so the
        // paged glance can be verified without a paired iPhone pushing a context. It
        // only ever writes the deterministic, DEMO-flagged fixture — no fake "live"
        // data is ever synthesized — and does nothing unless the argument is present.
        WatchLaunchSeed.applyIfNeeded()
        _receiver = State(initialValue: WatchSnapshotReceiver())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // Screenshot-only seam: render the accessoryCircular double-ring
                // complication at true watch-face point size for capture, since a
                // real watch-face complication can't be added via `simctl`.
                if ProcessInfo.processInfo.arguments.contains("-tr-widget-gallery") {
                    if ProcessInfo.processInfo.arguments.contains("-tr-corner") {
                        WatchCornerGaugePreview(snapshot: SnapshotStore.shared.readOrEmpty(now: Date()))
                    } else {
                        WatchComplicationGallery(snapshot: SnapshotStore.shared.readOrEmpty(now: Date()))
                    }
                } else {
                    WatchGlanceView()
                        .environment(receiver)
                        .onAppear { receiver.activate() }
                }
            }
        }
    }
}

/// Approximates the `accessoryCorner` family (`TRWatchCorner`): the min-remaining %
/// tucked in the watch's bottom-leading corner, with a curved bezel gauge of that
/// same value hugging the edge. The real curving is applied by the system's on-face
/// complication renderer, which a plain SwiftUI gallery can't invoke — so this shows
/// the design at the corner's canonical placement rather than the raw uncurved family.
struct WatchCornerGaugePreview: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let entry = TREntry(snapshot: snapshot, now: Date())
        VStack(spacing: 10) {
            Text("accessoryCorner")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
            // The corner content: the dual-arc AI mark (outer Claude coral, inner
            // Codex blue, robot centre). Shown large so both arcs + robot are visible.
            MiniDualArc(
                outerRemaining: entry.remainingPercent(for: .claude) ?? entry.minRemainingPercent ?? 0,
                innerRemaining: entry.remainingPercent(for: .codex) ?? entry.minRemainingPercent ?? 0,
                size: 84
            )
            // The curved bezel label (rendered straight here — the real curving is
            // applied by the on-face complication renderer).
            Text("AI 用量 · \(TRL10n.t("overview.min_remaining")) \(entry.heroText)")
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .foregroundStyle(TRTheme.text)
            // The same mark at its true ~26pt corner-content size, for honesty.
            HStack(spacing: 6) {
                MiniDualArc(
                    outerRemaining: entry.remainingPercent(for: .claude) ?? entry.minRemainingPercent ?? 0,
                    innerRemaining: entry.remainingPercent(for: .codex) ?? entry.minRemainingPercent ?? 0,
                    size: 26
                )
                Text("真实角标尺寸")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(TRTheme.textMute)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TRTheme.ink)
    }
}

/// Renders the exact `ActivityRings` the `TRWatchRemainGauge` complication uses,
/// framed as an `accessoryCircular` slot (~52pt), plus the corner/inline previews.
struct WatchComplicationGallery: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let entry = TREntry(snapshot: snapshot, now: Date())
        VStack(spacing: 10) {
            Text("accessoryCircular")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
            ActivityRings(
                outerRemaining: entry.remainingPercent(for: .claude) ?? entry.minRemainingPercent ?? 0,
                innerRemaining: entry.remainingPercent(for: .codex) ?? entry.minRemainingPercent ?? 0,
                outerColor: TRTheme.claudeBrand,
                innerColor: TRTheme.codexBrand,
                centerLabel: entry.heroText
            )
            .frame(width: 52, height: 52)
            HStack(spacing: 10) {
                VStack(spacing: 2) {
                    ProviderGlyph(provider: .claude, size: 16)
                    Text("Claude").font(.system(size: 9, design: .monospaced)).foregroundStyle(TRTheme.text)
                }
                VStack(spacing: 2) {
                    ProviderGlyph(provider: .codex, size: 16)
                    Text("Codex").font(.system(size: 9, design: .monospaced)).foregroundStyle(TRTheme.text)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TRTheme.ink)
    }
}

enum WatchLaunchSeed {
    static func applyIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if arguments.contains("-tr-origin-none") {
            SnapshotStore.shared.clear()
            return
        }
        guard let index = arguments.firstIndex(of: "-tr-demo"), index + 1 < arguments.count,
              let scenario = DemoScenario(rawValue: arguments[index + 1]) else { return }
        SnapshotStore.shared.write(SnapshotComposer.demo(scenario: scenario, now: Date()))
    }

    /// `-tr-watch-page <0…3>` pins the initial glance page for deterministic
    /// screenshots (the crown still pages freely afterwards).
    static func initialPage(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int {
        guard let index = arguments.firstIndex(of: "-tr-watch-page"), index + 1 < arguments.count,
              let page = Int(arguments[index + 1]) else { return 0 }
        return min(3, max(0, page))
    }
}

/// The watch is **view-only** by contract: paged glance screens, no settings, no
/// actions, no scenario switching, no Live Activity control. It renders the last
/// snapshot the iPhone pushed, plus staleness — it never composes or projects data.
///
/// Four vertically-paged screens carry popover-level density:
/// 1. Overview — risk, hero 最低剩余, pace, both providers.
/// 2. Claude — coral starburst, per-window meters + resets + pace.
/// 3. Codex — terminal-prompt mark, 7-day window + reset + pace.
/// 4. 今日用量 — tokens + cost split, with the data-source / provenance caption.
struct WatchGlanceView: View {
    @Environment(WatchSnapshotReceiver.self) private var receiver
    @State private var selection: Int = WatchLaunchSeed.initialPage()

    var body: some View {
        if receiver.snapshot.isEmpty {
            WatchEmptyView()
        } else {
            TabView(selection: $selection) {
                WatchOverviewPage(snapshot: receiver.snapshot).tag(0)
                WatchProviderPage(snapshot: receiver.snapshot, provider: .claude).tag(1)
                WatchProviderPage(snapshot: receiver.snapshot, provider: .codex).tag(2)
                WatchTodayPage(snapshot: receiver.snapshot, receivedAt: receiver.receivedAt).tag(3)
            }
            .tabViewStyle(.verticalPage)
            .background(TRTheme.ink)
        }
    }
}

struct WatchEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            PixelRobot(remainingPercent: 0, size: 48)
                .accessibilityHidden(true)
            Text(TRL10n.t("watch.waiting"))
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(TRTheme.text)
            Text(TRL10n.t("watch.waiting.body"))
                .font(.caption2)
                .foregroundStyle(TRTheme.textDim)
                .multilineTextAlignment(.center)
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tr.watch.emptyState")
    }
}

// MARK: - Page 1 · Overview

struct WatchOverviewPage: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let now = Date()
        let insights = snapshot.insights
        let risk = insights.riskLevel(at: now)
        let lasts = insights.willLastUntilReset(at: now)
        let hero = TREntry(snapshot: snapshot, now: now).heroText
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                WatchRiskBadge(risk: risk)
                if snapshot.isDemo { DemoChip(compact: true) }
                Spacer(minLength: 0)
                PixelRobot(remainingPercent: insights.minRemainingPercent, size: 22)
                    .accessibilityHidden(true)
            }
            Text(TRL10n.t("overview.min_remaining"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
            Text(hero)
                .trValue(size: 38)
                .foregroundStyle(TRTheme.text)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            WatchPaceLine(lasts: lasts, risk: risk)
            Divider().overlay(TRTheme.border)
            ForEach(ProviderQuota.Provider.allCases, id: \.self) { provider in
                if let lead = insights.leadWindow(for: provider) {
                    WatchProviderMiniRow(provider: provider, window: lead)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tr.watch.overview")
        .accessibilityLabel(
            "\(TRL10n.t("overview.risk.caption"))\(risk.headline)，"
            + "\(TRL10n.t("overview.min_remaining")) \(hero)，"
            + (lasts ? TRL10n.t("pace.short.ok") : TRL10n.t("pace.short.early"))
            + (snapshot.isDemo ? "，\(TRL10n.t("demo.a11y"))" : "")
        )
    }
}

// MARK: - Page 2 & 3 · Provider detail

struct WatchProviderPage: View {
    let snapshot: UsageSnapshot
    let provider: ProviderQuota.Provider

    var body: some View {
        let now = Date()
        let insights = snapshot.insights
        let windows = insights.windows(for: provider)
        let quota = provider == .claude ? insights.claude : insights.codex
        let accent = TRTheme.accent(for: provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderGlyph(provider: provider, size: 18)
                Text(provider.shortName)
                    .font(.system(size: 15, design: .monospaced).weight(.semibold))
                    .foregroundStyle(TRTheme.text)
                Spacer(minLength: 0)
                if let plan = quota?.planName {
                    PixelBadge(plan, accent: accent)
                }
                if snapshot.isDemo { DemoChip(compact: true) }
            }
            if windows.isEmpty {
                Text(TRL10n.t("limits.reset.unknown"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TRTheme.textDim)
            } else {
                ForEach(windows) { window in
                    WatchWindowBlock(window: window, accent: accent, now: now)
                }
                if let assessment = insights.paceAssessment(at: now),
                   assessment.window.provider == provider,
                   let runOut = assessment.pace.estimatedRunOutAt {
                    HStack(spacing: 4) {
                        PixelCheck(.warn, size: 9, accent: TRTheme.danger)
                        Text(TRL10n.f("overview.pace.runout", UsageFormatting.durationUntil(runOut, now: now)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TRTheme.danger)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    HStack(spacing: 4) {
                        PixelCheck(.checked, size: 9, accent: TRTheme.success)
                        Text(TRL10n.t("pace.short.ok"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TRTheme.success)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tr.watch.provider.\(provider.rawValue)")
        .accessibilityLabel(providerAccessibilityLabel(windows: windows, now: now))
    }

    private func providerAccessibilityLabel(windows: [UsageInsights.Window], now: Date) -> String {
        var parts = [provider.shortName]
        for window in windows {
            parts.append("\(UsageFormatting.windowName(minutes: window.windowMinutes)) "
                + UsageFormatting.percent(window.remainingPercent.rounded()))
        }
        if snapshot.isDemo { parts.append(TRL10n.t("demo.a11y")) }
        return parts.joined(separator: "，")
    }
}

/// One window inside a provider page: title + big remaining %, meter, reset line.
struct WatchWindowBlock: View {
    let window: UsageInsights.Window
    let accent: Color
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageFormatting.windowName(minutes: window.windowMinutes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TRTheme.textDim)
                Spacer(minLength: 0)
                Text(UsageFormatting.percent(window.remainingPercent.rounded()))
                    .font(.system(size: 16, design: .monospaced).monospacedDigit().weight(.semibold))
                    .foregroundStyle(TRTheme.text)
            }
            SegmentBar(remainingPercent: window.remainingPercent, accent: accent, segments: 12, height: 5)
            Text(resetLine)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(TRTheme.textMute)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var resetLine: String {
        guard let resetsAt = window.resetsAt else { return TRL10n.t("limits.reset.unknown") }
        return UsageFormatting.resetDescription(to: resetsAt, now: now)
    }
}

// MARK: - Page 4 · Today's usage + provenance

struct WatchTodayPage: View {
    let snapshot: UsageSnapshot
    let receivedAt: Date?

    var body: some View {
        let now = Date()
        let insights = snapshot.insights
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(TRL10n.t("today.title"))
                    .font(.system(size: 14, design: .monospaced).weight(.semibold))
                    .foregroundStyle(TRTheme.text)
                Spacer(minLength: 0)
                if snapshot.isDemo { DemoChip(compact: true) }
            }
            if let total = insights.totalTokens, let cost = insights.totalCost {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    todayMetric(TRL10n.t("today.tokens"), UsageFormatting.compactNumber(total), color: TRTheme.text)
                    todayMetric(TRL10n.t("today.cost"), String(format: "$%.2f", cost), color: TRTheme.text)
                }
                .padding(.top, 1)
                ForEach(insights.dailyTokens ?? []) { agent in
                    todaySplitRow(agent)
                }
            } else {
                Text(TRL10n.t("today.empty"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TRTheme.textDim)
            }
            Divider().overlay(TRTheme.border)
            Text(snapshot.isDemo ? TRL10n.t("today.source.demo") : TRL10n.t("privacy.statement"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(TRL10n.f("watch.provenance", UsageFormatting.freshnessDescription(since: snapshot.generatedAt, now: now)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(TRTheme.textMute)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tr.watch.today")
        .accessibilityLabel(todayAccessibilityLabel(insights: insights, now: now))
    }

    private func todayMetric(_ caption: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
            Text(value)
                .font(.system(size: 17, design: .monospaced).monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private func todaySplitRow(_ agent: AgentTokens) -> some View {
        let provider: ProviderQuota.Provider = agent.id == "codex" ? .codex : .claude
        return HStack(spacing: 6) {
            Circle()
                .fill(TRTheme.accent(for: provider))
                .frame(width: 6, height: 6)
            Text(provider.shortName)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
            Spacer(minLength: 0)
            Text(UsageFormatting.compactNumber(agent.tokens))
                .font(.system(size: 10, design: .monospaced).monospacedDigit())
                .foregroundStyle(TRTheme.text)
            Text(String(format: "$%.2f", agent.estimatedCost))
                .font(.system(size: 10, design: .monospaced).monospacedDigit())
                .foregroundStyle(TRTheme.textDim)
        }
        .accessibilityHidden(true)
    }

    private func todayAccessibilityLabel(insights: UsageInsights, now: Date) -> String {
        var parts = [TRL10n.t("today.title")]
        if let total = insights.totalTokens, let cost = insights.totalCost {
            parts.append("\(TRL10n.t("today.tokens")) \(UsageFormatting.compactNumber(total))")
            parts.append("\(TRL10n.t("today.cost")) \(String(format: "$%.2f", cost))")
        } else {
            parts.append(TRL10n.t("today.empty"))
        }
        parts.append(TRL10n.f("watch.provenance", UsageFormatting.freshnessDescription(since: snapshot.generatedAt, now: now)))
        if snapshot.isDemo { parts.append(TRL10n.t("demo.a11y")) }
        return parts.joined(separator: "，")
    }
}

// MARK: - Shared compact components

/// Filled semantic risk badge: colour + short label + glyph, never hue alone.
struct WatchRiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        HStack(spacing: 3) {
            Text(TRL10n.t("risk.short.\(risk.rawValue)"))
                .font(.system(size: 11, design: .monospaced).weight(.bold))
            if !risk.glyph.isEmpty {
                Text(risk.glyph)
                    .font(.system(size: 10, design: .monospaced).weight(.bold))
            }
        }
        .foregroundStyle(TRTheme.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(TRTheme.riskSemantic(risk), in: RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

/// The pace judgement line: pixel glyph + semantic colour + text label.
struct WatchPaceLine: View {
    let lasts: Bool
    let risk: RiskLevel

    private var color: Color {
        lasts ? TRTheme.success : (risk == .high ? TRTheme.danger : TRTheme.warning)
    }

    var body: some View {
        HStack(spacing: 4) {
            PixelCheck(lasts ? .checked : .warn, size: 11, accent: color)
            Text(lasts ? TRL10n.t("pace.short.ok") : TRL10n.t("pace.short.early"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityHidden(true)
    }
}

/// Compact provider row on the Overview page: glyph + name + meter + %.
struct WatchProviderMiniRow: View {
    let provider: ProviderQuota.Provider
    let window: UsageInsights.Window

    var body: some View {
        HStack(spacing: 6) {
            ProviderGlyph(provider: provider, size: 13)
            Text(provider.shortName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TRTheme.text)
                .frame(width: 44, alignment: .leading)
            SegmentBar(remainingPercent: window.remainingPercent,
                       accent: TRTheme.accent(for: provider), segments: 8, height: 4)
            Text(UsageFormatting.percent(window.remainingPercent.rounded()))
                .font(.system(size: 11, design: .monospaced).monospacedDigit())
                .foregroundStyle(TRTheme.text)
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }
}

#Preview("Overview") {
    WatchOverviewPage(snapshot: SnapshotComposer.demo(scenario: .concept, now: SnapshotComposer.previewNow))
        .background(TRTheme.ink)
}

#Preview("Claude") {
    WatchProviderPage(snapshot: SnapshotComposer.demo(scenario: .concept, now: SnapshotComposer.previewNow),
                      provider: .claude)
        .background(TRTheme.ink)
}

#Preview("Codex · deficit") {
    WatchProviderPage(snapshot: SnapshotComposer.demo(scenario: .deficitPace, now: SnapshotComposer.previewNow),
                      provider: .codex)
        .background(TRTheme.ink)
}

#Preview("Today") {
    WatchTodayPage(snapshot: SnapshotComposer.demo(scenario: .concept, now: SnapshotComposer.previewNow),
                   receivedAt: SnapshotComposer.previewNow)
        .background(TRTheme.ink)
}
