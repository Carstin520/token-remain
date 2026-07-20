import SwiftUI
import TokenRemainKit
import WidgetKit

// MARK: - Shared pieces

/// The 4×4-pixel demo mark used on every non-app surface.
struct WidgetDemoMark: View {
    var body: some View {
        Text("D̸")
            .font(.system(size: 9, design: .monospaced).weight(.bold))
            .foregroundStyle(TRTheme.indigo)
            .accessibilityElement()
            .accessibilityLabel(TRL10n.t("demo.a11y"))
    }
}

/// Honest `.none` state for every widget family: robot offline, no numbers.
struct WidgetEmptyView: View {
    var compact = false

    var body: some View {
        VStack(spacing: 4) {
            PixelRobot(remainingPercent: 0, size: compact ? 24 : 40)
                .accessibilityHidden(true)
            Text(TRL10n.t("origin.none.status"))
                .font(.system(size: compact ? 9 : 11, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TRL10n.t("origin.none.title"))
    }
}

/// Pace-line colour shared by the home widgets: green when it lasts, red at high
/// risk, amber otherwise — always paired with the `PixelCheck` shape + a text label.
private func paceColor(lasts: Bool, risk: RiskLevel) -> Color {
    lasts ? TRTheme.success : (risk == .high ? TRTheme.danger : TRTheme.warning)
}

extension TREntry {
    /// One composed VoiceOver sentence, reused across widgets and complications.
    var accessibilitySummary: String {
        guard hasNumbers else { return TRL10n.t("origin.none.title") }
        var parts = ["\(TRL10n.t("overview.min_remaining")) \(heroText)", paceLine]
        if let soonestReset {
            parts.append(TRL10n.f("reset.countdown", UsageFormatting.durationUntil(soonestReset, now: date)))
        }
        if isDemo { parts.append(TRL10n.t("demo.a11y")) }
        return parts.joined(separator: "，")
    }
}

// MARK: - Home Screen: small

struct TRHeroView: View {
    let entry: TREntry

    var body: some View {
        Group {
            if entry.hasNumbers {
                VStack(spacing: 6) {
                    HStack {
                        PixelRobot(remainingPercent: entry.minRemainingPercent, size: 34)
                            .accessibilityHidden(true)
                        Spacer()
                        if entry.isDemo { WidgetDemoMark() }
                    }
                    Text(entry.heroText)
                        .trValue(size: 34)
                        .foregroundStyle(TRTheme.cyan)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        RiskBadge(entry.risk)
                        PixelCheck(entry.willLastUntilReset ? .checked : .warn,
                                   size: 10,
                                   accent: paceColor(lasts: entry.willLastUntilReset, risk: entry.risk))
                        Spacer()
                    }
                }
            } else {
                WidgetEmptyView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilitySummary)
    }
}

// MARK: - Home Screen: medium

struct TRProvidersView: View {
    let entry: TREntry

    var body: some View {
        Group {
            if entry.hasNumbers {
                HStack(alignment: .top, spacing: 14) {
                    // Left column: robot mood, min-remaining hero, semantic risk badge.
                    VStack(alignment: .leading, spacing: 5) {
                        PixelRobot(remainingPercent: entry.minRemainingPercent, size: 30)
                            .accessibilityHidden(true)
                        Text(TRL10n.t("overview.min_remaining"))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(TRTheme.textDim)
                        Text(entry.heroText)
                            .trValue(size: 30)
                            .foregroundStyle(TRTheme.cyan)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        RiskBadge(entry.risk, compact: true)
                    }
                    .frame(width: 92, alignment: .leading)

                    // Right column: provider rows, reset countdown, pace verdict.
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Spacer()
                            if entry.isDemo { WidgetDemoMark() }
                        }
                        .frame(height: entry.isDemo ? nil : 0)
                        ForEach(entry.providers) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    ProviderGlyph(provider: line.provider, size: 13)
                                    Text(line.displayName)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(TRTheme.text)
                                    Spacer()
                                    Text(UsageFormatting.percent(line.remainingPercent.rounded()))
                                        .font(.system(.footnote, design: .monospaced).monospacedDigit())
                                        .foregroundStyle(TRTheme.text)
                                }
                                SegmentBar(
                                    remainingPercent: line.remainingPercent,
                                    accent: TRTheme.accent(for: line.provider),
                                    segments: 14,
                                    height: 5
                                )
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Text(TRL10n.t("overview.reset.card"))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TRTheme.textDim)
                            if let reset = entry.soonestReset {
                                Text(reset, style: .timer)
                                    .font(.system(size: 13, design: .monospaced).monospacedDigit().weight(.semibold))
                                    .foregroundStyle(TRTheme.cyan)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            } else {
                                Text(TRL10n.t("limits.reset.unknown"))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TRTheme.textDim)
                            }
                        }
                        HStack(spacing: 4) {
                            PixelCheck(entry.willLastUntilReset ? .checked : .warn, size: 9,
                                       accent: paceColor(lasts: entry.willLastUntilReset, risk: entry.risk))
                            Text(entry.paceLine)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(paceColor(lasts: entry.willLastUntilReset, risk: entry.risk))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                }
            } else {
                WidgetEmptyView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilitySummary)
    }
}

// MARK: - Lock Screen accessories

struct TRInlineView: View {
    let entry: TREntry

    var body: some View {
        if entry.hasNumbers {
            Text("AI \(entry.isDemo ? "D̸ " : "")\(entry.heroText) · \(entry.paceLine)")
                .accessibilityLabel(entry.accessibilitySummary)
        } else {
            Text(TRL10n.t("origin.none.status"))
                .accessibilityLabel(TRL10n.t("origin.none.title"))
        }
    }
}

struct TRCircularView: View {
    let entry: TREntry

    var body: some View {
        Group {
            if entry.hasNumbers {
                // Same double-ring design as the watch complication so the two
                // surfaces read identically: outer Claude, inner Codex, min % centre.
                // Lock Screen is a face-like surface → brand-coloured meters.
                ActivityRings(
                    outerRemaining: entry.remainingPercent(for: .claude) ?? entry.minRemainingPercent ?? 0,
                    innerRemaining: entry.remainingPercent(for: .codex) ?? entry.minRemainingPercent ?? 0,
                    outerColor: TRTheme.claudeBrand,
                    innerColor: TRTheme.codexBrand,
                    centerLabel: entry.heroText
                )
                .padding(1)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    PixelRobot(remainingPercent: 0, size: 30, monochrome: true)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilitySummary)
    }
}

struct TRResetCircularView: View {
    let entry: TREntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                if let reset = entry.soonestReset {
                    Text(reset, style: .timer)
                        .font(.system(size: 13, design: .monospaced).monospacedDigit())
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.hasNumbers
            ? entry.accessibilitySummary
            : TRL10n.t("origin.none.title"))
    }
}

struct TRRectangularView: View {
    let entry: TREntry

    var body: some View {
        Group {
            if entry.hasNumbers {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            // AI-usage eyebrow, then the min-remaining hero.
                            Text("AI 用量")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TRTheme.textDim)
                            Text(TRL10n.t("overview.min_remaining"))
                                .font(.system(size: 9, design: .monospaced))
                            Text(entry.heroText)
                                .font(.system(size: 17, design: .monospaced).monospacedDigit().weight(.semibold))
                            if entry.isDemo {
                                Text("D̸").font(.system(size: 9, design: .monospaced))
                            }
                            Spacer(minLength: 0)
                        }
                        if let reset = entry.soonestReset {
                            Text("\(TRL10n.f("reset.countdown", UsageFormatting.shortCountdown(to: reset, now: entry.date))) · \(UsageFormatting.absoluteReset(reset))")
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        // Provider mini-bars — brand colours on this Lock Screen surface
                        // (Claude coral, Codex blue), each already labelled by its glyph.
                        ForEach(entry.providers) { line in
                            HStack(spacing: 5) {
                                ProviderGlyph(provider: line.provider, size: 10)
                                SegmentBar(
                                    remainingPercent: line.remainingPercent,
                                    accent: TRTheme.brandColor(for: line.provider),
                                    segments: 10,
                                    height: 3
                                )
                                Text(UsageFormatting.percent(line.remainingPercent.rounded()))
                                    .font(.system(size: 9, design: .monospaced).monospacedDigit())
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    PixelRobot(remainingPercent: 0, size: 24, monochrome: true)
                        .accessibilityHidden(true)
                    Text(TRL10n.t("origin.none.status"))
                        .font(.system(size: 12, design: .monospaced))
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilitySummary)
    }
}
