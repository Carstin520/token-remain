import SwiftUI
import TokenRemainKit

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
                            ForEach(model.insights.windows) { window in
                                WindowDetailCard(
                                    window: window,
                                    highlighted: model.highlightedWindowID == window.id,
                                    reduceMotion: reduceMotion
                                )
                                .id(window.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
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

struct WindowDetailCard: View {
    let window: UsageInsights.Window
    let highlighted: Bool
    let reduceMotion: Bool

    @Environment(AppModel.self) private var model
    @State private var pulse = false

    private var accent: Color { TRTheme.accent(for: window.provider) }

    var body: some View {
        let now = Date()
        let pace = model.insights.pace(for: window, at: now)
        PixelCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                SegmentBar(remainingPercent: window.remainingPercent, accent: accent)
                    .neonGlow(accent, intensity: 0.4)
                paceSection(pace: pace, now: now)
                Divider().overlay(TRTheme.border)
                resetSection(now: now)
            }
        }
        // Structure layer: scanlines + faint neon border in the provider accent (key card).
        .cyberCard(border: accent)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(TRTheme.indigo, lineWidth: highlighted && pulse ? 2 : 0)
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
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tr.limits.window.\(window.id)")
        .accessibilityLabel(accessibilityLabel(pace: pace, now: now))
    }

    private var header: some View {
        TRAdaptiveRow {
            ProviderGlyph(provider: window.provider, size: 16)
            Text(window.title)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(TRTheme.text)
            Spacer(minLength: 0)
            // Display layer: dot-matrix window hero % with a neon bloom in the
            // provider accent (violet Claude / cyan Codex).
            CyberValue(
                UsageFormatting.percent(window.remainingPercent.rounded()),
                size: 30,
                color: TRTheme.text,
                glow: accent
            )
        }
    }

    @ViewBuilder
    private func paceSection(pace: UsagePace?, now: Date) -> some View {
        if let pace {
            VStack(alignment: .leading, spacing: 6) {
                TRAdaptiveRow {
                    metric(TRL10n.t("limits.pace.expected"), UsageFormatting.percent(pace.expectedUsedPercent.rounded()))
                    metric(TRL10n.t("limits.pace.actual"), UsageFormatting.percent(pace.actualUsedPercent.rounded()))
                    metric(TRL10n.t("limits.pace.delta"), signed(pace.deltaPercent))
                    Spacer(minLength: 0)
                    PixelBadge(statusLabel(pace.status), accent: statusAccent(pace.status))
                        .neonGlow(statusAccent(pace.status), intensity: 0.5)
                }
                if let runOut = pace.estimatedRunOutAt {
                    // Always phrased as an estimate — never as a fact.
                    Label(
                        TRL10n.f("limits.pace.projected", UsageFormatting.durationUntil(runOut, now: now)),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(TRTheme.violet)
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
            Text(caption)
                .font(.caption)
                .foregroundStyle(TRTheme.textDim)
            Text(value)
                .font(.system(.footnote, design: .monospaced).monospacedDigit())
                .foregroundStyle(TRTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case .reserve: return TRTheme.cyan
        case .deficit: return TRTheme.violet
        }
    }

    private func resetSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(TRL10n.t("limits.reset.section"))
                .font(.caption)
                .foregroundStyle(TRTheme.textDim)
            if let resetsAt = window.resetsAt {
                let description = UsageFormatting.resetDescription(to: resetsAt, now: now)
                let absolute = UsageFormatting.absoluteReset(resetsAt)
                Text(description)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(TRTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                // For far resets `resetDescription` already reads "周五 12:37 重置", so the
                // absolute clock line would just repeat it — only show it when it adds
                // information (e.g. the near-reset countdown case "重置还有 02:38").
                if !description.contains(absolute) {
                    Text(absolute)
                        .font(.caption)
                        .foregroundStyle(TRTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Claude can report a fresh window before it knows the next reset.
                // That stays unknown rather than being invented.
                Text(TRL10n.t("limits.reset.unknown"))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(TRTheme.textDim)
            }
        }
    }

    private func accessibilityLabel(pace: UsagePace?, now: Date) -> String {
        var parts = [
            window.title,
            "\(TRL10n.t("overview.min_remaining")) \(UsageFormatting.percent(window.remainingPercent.rounded()))"
        ]
        if let pace {
            parts.append(statusLabel(pace.status))
            if let runOut = pace.estimatedRunOutAt {
                parts.append(TRL10n.f("limits.pace.projected", UsageFormatting.durationUntil(runOut, now: now)))
            }
        }
        if let resetsAt = window.resetsAt {
            parts.append(UsageFormatting.resetDescription(to: resetsAt, now: now))
        } else {
            parts.append(TRL10n.t("limits.reset.unknown"))
        }
        if model.snapshot.isDemo { parts.append(TRL10n.t("demo.a11y")) }
        return parts.joined(separator: "，")
    }
}

#Preview("Limits · critical") {
    LimitsTab()
        .environment(AppModel(arguments: ["-tr-demo", "critical"]))
        .preferredColorScheme(.dark)
}
