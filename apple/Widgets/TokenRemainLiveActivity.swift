import ActivityKit
import AppIntents
import SwiftUI
import TokenRemainKit
import WidgetKit

/// User-started Live Activity. Local updates only — `pushType` is nil at request
/// time, so no remote-update capability is implied anywhere in the UI.
struct TokenRemainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TokenRemainActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(TRTheme.ink)
                .activitySystemActionForegroundColor(TRTheme.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 3) {
                        TokenRemainHeadLogo(
                            claudeRemaining: context.state.remainingPercent(for: .claude),
                            codexRemaining: context.state.remainingPercent(for: .codex),
                            size: 24
                        )
                            .accessibilityHidden(true)
                        HStack(spacing: 2) {
                            if context.state.isDemo {
                                Text("D")
                                    .foregroundStyle(TRTheme.indigo)
                            }
                            Text(String(Int(context.state.minRemainingPercent.rounded())))
                                .foregroundStyle(TRTheme.cyan)
                        }
                        .font(.system(size: 14, design: .monospaced).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(TRL10n.t("overview.min_remaining")) \(context.state.heroText)")
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(context.state.providers) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(line.name)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(TRTheme.text)
                                    Spacer()
                                    Text(UsageFormatting.percent(line.remainingPercent.rounded()))
                                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                                        .foregroundStyle(TRTheme.text)
                                }
                                SegmentBar(
                                    remainingPercent: line.remainingPercent,
                                    accent: TRTheme.accent(for: line.provider),
                                    segments: 10,
                                    height: 4
                                )
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(line.name) \(UsageFormatting.percent(line.remainingPercent.rounded()))")
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        PixelCheck(
                            context.state.willLastUntilReset ? .checked : .warn,
                            size: 10,
                            accent: context.state.willLastUntilReset ? TRTheme.cyan : TRTheme.violet
                        )
                        if let reset = context.state.soonestReset {
                            Text(UsageFormatting.shortCountdown(to: reset, now: context.state.generatedAt))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TRTheme.textDim)
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                        }
                        if isStale(context.state) {
                            Text(TRL10n.t("liveactivity.stale"))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TRTheme.textDim)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(paceText(context.state))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: RefreshSnapshotIntent()) {
                        Label(TRL10n.t("liveactivity.refresh"), systemImage: "arrow.clockwise")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .tint(TRTheme.indigo)
                    .accessibilityLabel(TRL10n.t("intent.refresh.title"))
                }
            } compactLeading: {
                TokenRemainHeadLogo(
                    claudeRemaining: context.state.remainingPercent(for: .claude),
                    codexRemaining: context.state.remainingPercent(for: .codex),
                    size: 18
                )
                    .accessibilityHidden(true)
            } compactTrailing: {
                HStack(spacing: 2) {
                    if context.state.isDemo {
                        Text("D")
                            .foregroundStyle(TRTheme.indigo)
                    }
                    Text(context.state.heroText)
                        .foregroundStyle(TRTheme.violet)
                }
                    .font(.system(size: 13, design: .monospaced).monospacedDigit())
                    .accessibilityLabel("\(TRL10n.t("overview.min_remaining")) \(context.state.heroText)")
            } minimal: {
                TokenRemainHeadLogo(
                    claudeRemaining: context.state.remainingPercent(for: .claude),
                    codexRemaining: context.state.remainingPercent(for: .codex),
                    size: 16
                )
                    .accessibilityLabel("\(TRL10n.t("overview.min_remaining")) \(context.state.heroText)")
            }
            .widgetURL(TRRoute.overview.url)
            .keylineTint(TRTheme.violet)
        }
    }

    private func paceText(_ state: TokenRemainActivityAttributes.ContentState) -> String {
        guard let runOut = state.runOutAt, !state.willLastUntilReset else {
            return TRL10n.t("overview.pace.ok")
        }
        return TRL10n.f("overview.pace.runout", UsageFormatting.durationUntil(runOut, now: state.generatedAt))
    }

    private func isStale(_ state: TokenRemainActivityAttributes.ContentState) -> Bool {
        state.isStale(at: Date())
    }
}

struct LockScreenLiveActivityView: View {
    let state: TokenRemainActivityAttributes.ContentState

    private var isStale: Bool { state.isStale(at: Date()) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TokenRemainHeadLogo(
                    claudeRemaining: state.remainingPercent(for: .claude),
                    codexRemaining: state.remainingPercent(for: .codex),
                    size: 34
                )
                    .accessibilityHidden(true)
                Text(TRL10n.t("overview.min_remaining"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(TRTheme.textDim)
                Text(state.heroText)
                    .trValue(size: 24)
                    .foregroundStyle(TRTheme.cyan)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(state.providers) { line in
                    HStack(spacing: 6) {
                        Text(line.name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TRTheme.textDim)
                            .frame(width: 44, alignment: .leading)
                        SegmentBar(
                            remainingPercent: line.remainingPercent,
                            accent: TRTheme.accent(for: line.provider),
                            segments: 10,
                            height: 4
                        )
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                if state.isDemo { WidgetDemoMark() }
                if let reset = state.soonestReset {
                    Text(reset, style: .timer)
                        .trValue(size: 18)
                        .foregroundStyle(TRTheme.cyan)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: 76)
                }
                if isStale {
                    Text(TRL10n.t("liveactivity.stale"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(TRTheme.textDim)
                }
            }
        }
        .padding(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["\(TRL10n.t("overview.min_remaining")) \(state.heroText)"]
        parts.append(state.willLastUntilReset ? TRL10n.t("overview.pace.ok") : TRL10n.t("risk.headline.medium"))
        if state.isDemo { parts.append(TRL10n.t("demo.a11y")) }
        if isStale { parts.append(TRL10n.t("liveactivity.stale")) }
        return parts.joined(separator: "，")
    }
}

private extension TokenRemainActivityAttributes.ContentState {
    func remainingPercent(for provider: ProviderQuota.Provider) -> Double? {
        providers.first { $0.provider == provider }?.remainingPercent
    }
}
