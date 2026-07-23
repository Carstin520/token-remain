import SwiftUI
import TokenRemainKit

/// The mobile Limits tab follows the Desktop Dashboard information hierarchy:
/// one provider card, then every official window with freshness, reset and pace.
struct LimitsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        CyberPageHeader(title: TRL10n.t("tab.limits"))
                        DemoHeaderRow()
                        if model.snapshot.isEmpty {
                            NotConnectedCard()
                        } else {
                            ForEach(ProviderQuota.Provider.allCases, id: \.self) { provider in
                                let windows = model.insights.windows(for: provider)
                                if !windows.isEmpty {
                                    ProviderLimitsCard(
                                        provider: provider,
                                        windows: windows,
                                        highlightedWindowID: model.highlightedWindowID,
                                        reduceMotion: reduceMotion
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 96)
                }
                .background(TRTheme.ink)
                .onChange(of: model.highlightedWindowID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onAppear {
                    guard let anchor = model.highlightedWindowID else { return }
                    proxy.scrollTo(anchor, anchor: .center)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct ProviderLimitsCard: View {
    @Environment(AppModel.self) private var model

    let provider: ProviderQuota.Provider
    let windows: [UsageInsights.Window]
    let highlightedWindowID: String?
    let reduceMotion: Bool

    private var quota: ProviderQuota? {
        model.snapshot.providers.first { $0.provider == provider }
    }

    private var accent: Color { TRTheme.accent(for: provider) }

    var body: some View {
        PixelCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().overlay(TRTheme.border)
                ForEach(windows) { window in
                    ProviderLimitWindowRow(
                        window: window,
                        highlighted: highlightedWindowID == window.id,
                        reduceMotion: reduceMotion
                    )
                    .id(window.id)
                    if window.id != windows.last?.id {
                        Divider().overlay(TRTheme.border)
                    }
                }
                freshness
            }
        }
        .cyberCard(border: TRTheme.accentDim(for: provider))
        .trGlassCard(enabled: model.glassEnabled)
        .accessibilityIdentifier("tr.limits.provider.\(provider.syncID)")
    }

    private var header: some View {
        TRAdaptiveRow {
            HStack(spacing: 8) {
                ProviderGlyph(provider: provider, size: 20)
                Text(provider.shortName)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(TRTheme.text)
                if let plan = quota?.planName, !plan.isEmpty {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TRTheme.textDim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(TRTheme.surface2, in: Capsule())
                }
            }
            Spacer(minLength: 8)
            if let lowest = windows.map(\.remainingPercent).min() {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(TRL10n.t("overview.min_remaining"))
                        .font(.caption2)
                        .foregroundStyle(TRTheme.textDim)
                    CyberValue(
                        UsageFormatting.percent(lowest.rounded()),
                        size: 22,
                        color: TRTheme.text,
                        glow: accent
                    )
                }
            }
        }
    }

    private var freshness: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let capturedAt = quota?.capturedAt ?? model.snapshot.generatedAt
            let stale = context.date.timeIntervalSince(capturedAt) >= UsageSnapshot.macSyncStaleInterval
            Label(
                TRL10n.f("limits.freshness", UsageFormatting.freshnessDescription(since: capturedAt, now: context.date)),
                systemImage: stale ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(stale ? TRTheme.warning : TRTheme.textDim)
        }
    }
}

/// Dense full-window detail. It deliberately uses only the already synchronized
/// fields and derives pace locally, so the Limits page never invents plan or
/// spend information missing from the privacy-minimized snapshot.
private struct ProviderLimitWindowRow: View {
    @Environment(AppModel.self) private var model

    let window: UsageInsights.Window
    let highlighted: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    private var accent: Color { TRTheme.accent(for: window.provider) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let pace = model.insights.pace(for: window, at: context.date)
            VStack(alignment: .leading, spacing: 9) {
                header
                SegmentBar(remainingPercent: window.remainingPercent, accent: accent)
                    .neonGlow(accent, intensity: 0.32)
                resetRow(now: context.date)
                paceDetails(pace: pace, now: context.date)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(TRTheme.indigo, lineWidth: highlighted && pulse ? 2 : 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("tr.limits.window.\(window.id)")
            .accessibilityLabel(accessibilityLabel(pace: pace, now: context.date))
        }
        .onChange(of: highlighted) { _, isHighlighted in
            guard isHighlighted else {
                pulse = false
                return
            }
            guard !reduceMotion else {
                pulse = true
                return
            }
            withAnimation(.easeInOut(duration: 0.5).repeatCount(4, autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var header: some View {
        TRAdaptiveRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(UsageFormatting.windowName(minutes: window.windowMinutes))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(TRTheme.text)
                Text(TRL10n.t("limits.window.caption"))
                    .font(.caption2)
                    .foregroundStyle(TRTheme.textMute)
            }
            Spacer(minLength: 8)
            CyberValue(
                UsageFormatting.percent(window.remainingPercent.rounded()),
                size: 28,
                color: TRTheme.text,
                glow: accent
            )
        }
    }

    private func resetRow(now: Date) -> some View {
        Label(resetDescription(now: now), systemImage: "arrow.clockwise")
            .font(.caption)
            .foregroundStyle(TRTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func paceDetails(pace: UsagePace?, now: Date) -> some View {
        if let pace {
            VStack(alignment: .leading, spacing: 6) {
                TRAdaptiveRow(spacing: 8) {
                    metric(TRL10n.t("limits.pace.expected"), UsageFormatting.percent(pace.expectedUsedPercent.rounded()))
                    metric(TRL10n.t("limits.pace.actual"), UsageFormatting.percent(pace.actualUsedPercent.rounded()))
                    metric(TRL10n.t("limits.pace.delta"), signed(pace.deltaPercent))
                    PixelBadge(statusLabel(pace.status), accent: statusAccent(pace.status))
                }
                if let runOut = pace.estimatedRunOutAt {
                    Label(
                        TRL10n.f("limits.pace.projected", UsageFormatting.durationUntil(runOut, now: now)),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(TRTheme.warning)
                } else {
                    Label(TRL10n.t("overview.pace.ok"), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(TRTheme.success)
                }
            }
        } else {
            Text(TRL10n.t("limits.pace.unavailable"))
                .font(.caption)
                .foregroundStyle(TRTheme.textMute)
        }
    }

    private func metric(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.caption2).foregroundStyle(TRTheme.textDim)
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

    private func statusLabel(_ status: UsagePace.Status) -> String {
        switch status {
        case .onTrack: return TRL10n.t("limits.pace.status.ontrack")
        case .reserve: return TRL10n.t("limits.pace.status.reserve")
        case .deficit: return TRL10n.t("limits.pace.status.deficit")
        }
    }

    private func statusAccent(_ status: UsagePace.Status) -> Color {
        switch status {
        case .onTrack: return TRTheme.indigo
        case .reserve: return TRTheme.success
        case .deficit: return TRTheme.warning
        }
    }

    private func accessibilityLabel(pace: UsagePace?, now: Date) -> String {
        var parts = [
            window.title,
            "\(TRL10n.t("overview.min_remaining")) \(UsageFormatting.percent(window.remainingPercent.rounded()))",
            resetDescription(now: now)
        ]
        if let pace {
            parts.append(statusLabel(pace.status))
            if let runOut = pace.estimatedRunOutAt {
                parts.append(TRL10n.f("limits.pace.projected", UsageFormatting.durationUntil(runOut, now: now)))
            }
        }
        if model.snapshot.isDemo { parts.append(TRL10n.t("demo.a11y")) }
        return parts.joined(separator: "，")
    }
}

#Preview("Limits · critical") {
    LimitsTab()
        .environment(AppModel(arguments: ["-tr-demo", "critical", "-tr-reset-overview-layout"]))
        .preferredColorScheme(.dark)
}
