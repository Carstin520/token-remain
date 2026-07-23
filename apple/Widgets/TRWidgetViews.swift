import SwiftUI
import TokenRemainKit
import WidgetKit

// MARK: - Shared pieces

/// The 4×4-pixel demo mark used on every non-app surface.
struct WidgetDemoMark: View {
    var body: some View {
        DemoChip(compact: true)
    }
}

struct WidgetStaleMark: View {
    var body: some View {
        Text(TRL10n.t("liveactivity.stale"))
            .font(.system(size: 8, design: .monospaced).weight(.semibold))
            .foregroundStyle(TRTheme.violet)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityHidden(true)
    }
}

/// Honest `.none` state for every widget family: robot offline, no numbers.
struct WidgetEmptyView: View {
    var compact = false
    var status: String? = nil

    private var resolvedStatus: String {
        status ?? TRL10n.t("origin.none.status")
    }

    var body: some View {
        VStack(spacing: 4) {
            TokenRemainHeadLogo(
                claudeRemaining: 0,
                codexRemaining: 0,
                size: compact ? 24 : 40
            )
                .accessibilityHidden(true)
            Text(resolvedStatus)
                .font(.system(size: compact ? 9 : 11, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(resolvedStatus)
    }
}

/// Match the app Overview hero: cyan confirms the current pace lasts until reset;
/// violet calls attention to a projected run-out. Shape + text still carry meaning.
private func paceColor(lasts: Bool) -> Color {
    lasts ? TRTheme.cyan : TRTheme.violet
}

/// Full-bleed home-widget surface. Home widgets opt out of WidgetKit's default
/// margins, then own one consistent inset and the same graphite / scanline /
/// pixel-corner treatment as the app's Overview hero card.
private struct WidgetSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TRTheme.surface)
            .overlay { ScanlineOverlay(spacing: 3, opacity: 0.025) }
            .overlay {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(TRTheme.violet.opacity(0.34), lineWidth: 1)
            }
            .overlay { WidgetCornerChrome() }
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
    }
}

private struct WidgetCornerChrome: View {
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let color = TRTheme.border
            let inset: CGFloat = 7
            let arm: CGFloat = 4
            let thickness: CGFloat = 1

            func fill(_ rect: CGRect) {
                context.fill(Path(rect), with: .color(color))
            }

            fill(CGRect(x: inset, y: inset, width: arm, height: thickness))
            fill(CGRect(x: inset, y: inset, width: thickness, height: arm))
            fill(CGRect(x: size.width - inset - arm, y: inset, width: arm, height: thickness))
            fill(CGRect(x: size.width - inset - thickness, y: inset, width: thickness, height: arm))

            for row in 0..<2 {
                for column in 0..<2 {
                    fill(CGRect(
                        x: size.width - inset - 7 + CGFloat(column) * 3,
                        y: size.height - inset - 7 + CGFloat(row) * 3,
                        width: 1.5,
                        height: 1.5
                    ))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WidgetHeader: View {
    let entry: TREntry

    var body: some View {
        HStack(spacing: 5) {
            Text("TokenRemain")
                .font(.system(size: 10, design: .monospaced).weight(.semibold))
                .foregroundStyle(TRTheme.text)
            Spacer(minLength: 2)
            if entry.isStale { WidgetStaleMark() }
            if entry.isDemo { WidgetDemoMark() }
            WidgetRiskMark(risk: entry.risk)
        }
        .frame(height: 16)
    }
}

/// The same outlined/filled risk treatment used by the app's Overview hero.
private struct WidgetRiskMark: View {
    let risk: RiskLevel

    var body: some View {
        HStack(spacing: 2) {
            PixelBadge(
                risk.badge,
                accent: TRTheme.riskAccent(risk),
                filled: TRTheme.riskIsFilled(risk)
            )
            if !risk.glyph.isEmpty {
                Text(risk.glyph)
                    .font(.system(size: 8, design: .monospaced).weight(.bold))
                    .foregroundStyle(TRTheme.riskAccent(risk))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WidgetProviderMeter: View {
    let line: TREntry.ProviderLine
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 2 : 3) {
            HStack(spacing: 4) {
                ProviderGlyph(provider: line.provider, size: compact ? 10 : 12)
                if !compact {
                    Text(line.displayName)
                        .font(.system(size: 10, design: .monospaced).weight(.medium))
                        .foregroundStyle(TRTheme.text)
                }
                Spacer(minLength: 2)
                Text(UsageFormatting.percent(line.remainingPercent.rounded()))
                    .font(.system(size: compact ? 9 : 10, design: .monospaced).monospacedDigit().weight(.semibold))
                    .foregroundStyle(TRTheme.text)
            }
            SegmentBar(
                remainingPercent: line.remainingPercent,
                accent: TRTheme.accent(for: line.provider),
                segments: compact ? 9 : 12,
                height: compact ? 3 : 4
            )
        }
    }
}

private struct WidgetResetLine: View {
    let entry: TREntry
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            PixelCheck(
                entry.willLastUntilReset ? .checked : .warn,
                size: compact ? 7 : 8,
                accent: paceColor(lasts: entry.willLastUntilReset)
            )
            Text(TRL10n.t("overview.reset.card"))
                .font(.system(size: compact ? 8 : 9, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
            if let reset = entry.soonestReset {
                Text(reset, style: .timer)
                    .font(.system(size: compact ? 9 : 11, design: .monospaced).monospacedDigit().weight(.semibold))
                    .foregroundStyle(TRTheme.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text(TRL10n.t("limits.reset.unknown"))
                    .font(.system(size: compact ? 8 : 9, design: .monospaced))
                    .foregroundStyle(TRTheme.textMute)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
    }
}

extension TREntry {
    /// One composed VoiceOver sentence, reused across widgets and complications.
    var accessibilitySummary: String {
        guard hasNumbers else {
            return isExpired ? TRL10n.t("origin.macsync.expired") : TRL10n.t("origin.none.title")
        }
        var parts = ["\(TRL10n.t("overview.min_remaining")) \(heroText)", paceLine]
        if let soonestReset {
            parts.append(TRL10n.f("reset.countdown", UsageFormatting.durationUntil(soonestReset, now: date)))
        }
        if isDemo { parts.append(TRL10n.t("demo.a11y")) }
        if isStale { parts.append(TRL10n.t("liveactivity.stale")) }
        return parts.joined(separator: "，")
    }
}

// MARK: - Home Screen: small

struct TRHeroView: View {
    let entry: TREntry

    var body: some View {
        WidgetSurface {
            if entry.hasNumbers {
                VStack(alignment: .leading, spacing: 0) {
                    WidgetHeader(entry: entry)

                    HStack(alignment: .center, spacing: 4) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(TRL10n.t("overview.min_remaining"))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(TRTheme.textDim)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            PixelDigitText(entry.heroText, size: 36, color: TRTheme.text)
                                .neonGlow(TRTheme.violet, intensity: 0.75)
                        }
                        Spacer(minLength: 0)
                        TokenRemainHeadLogo(
                            claudeRemaining: entry.remainingPercent(for: .claude),
                            codexRemaining: entry.remainingPercent(for: .codex),
                            size: 58
                        )
                        .accessibilityHidden(true)
                    }
                    .frame(height: 58)
                    .padding(.top, 2)

                    Spacer(minLength: 3)

                    VStack(spacing: 4) {
                        ForEach(entry.providers) { line in
                            WidgetProviderMeter(line: line, compact: true)
                        }
                    }

                    Spacer(minLength: 3)
                    WidgetResetLine(entry: entry, compact: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                WidgetEmptyView(compact: true, status: entry.paceLine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        WidgetSurface {
            if entry.hasNumbers {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(entry: entry)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(TRL10n.t("overview.min_remaining"))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TRTheme.textDim)
                            PixelDigitText(entry.heroText, size: 40, color: TRTheme.text)
                                .neonGlow(TRTheme.violet, intensity: 0.75)
                            HStack(spacing: 4) {
                                PixelCheck(
                                    entry.willLastUntilReset ? .checked : .warn,
                                    size: 8,
                                    accent: paceColor(lasts: entry.willLastUntilReset)
                                )
                                Text(entry.paceLine)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(paceColor(lasts: entry.willLastUntilReset))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.55)
                            }
                        }
                        .frame(width: 104, alignment: .leading)

                        Rectangle()
                            .fill(TRTheme.border)
                            .frame(width: 1, height: 92)

                        TokenRemainHeadLogo(
                            claudeRemaining: entry.remainingPercent(for: .claude),
                            codexRemaining: entry.remainingPercent(for: .codex),
                            size: 76
                        )
                        .accessibilityHidden(true)
                        .frame(width: 76)

                        Rectangle()
                            .fill(TRTheme.border)
                            .frame(width: 1, height: 92)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(entry.providers) { line in
                                WidgetProviderMeter(line: line)
                            }
                            Spacer(minLength: 0)
                            WidgetResetLine(entry: entry)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                WidgetEmptyView(status: entry.paceLine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text(inlineText)
                .accessibilityLabel(entry.accessibilitySummary)
        } else {
            Text(TRL10n.t("origin.none.status"))
                .accessibilityLabel(TRL10n.t("origin.none.title"))
        }
    }

    private var inlineText: String {
        let reset = entry.soonestReset.map {
            UsageFormatting.shortCountdown(to: $0, now: entry.date)
        } ?? "—"
        return "\(entry.heroText) · \(reset)"
            + (entry.isDemo ? " · D̸" : "")
            + (entry.isStale ? " · \(TRL10n.t("liveactivity.stale"))" : "")
    }
}

struct TRCircularView: View {
    let entry: TREntry

    var body: some View {
        Group {
            if entry.hasNumbers {
                // Same double-ring design as the watch complication so the two
                // surfaces read identically: outer Claude, inner Codex, min % centre.
                // Meters carry the muted provider accents; brand colour stays on logos.
                ActivityRings(
                    outerRemaining: entry.remainingPercent(for: .claude) ?? entry.minRemainingPercent ?? 0,
                    innerRemaining: entry.remainingPercent(for: .codex) ?? entry.minRemainingPercent ?? 0,
                    outerColor: TRTheme.claudeAccent,
                    innerColor: TRTheme.codexAccent,
                    centerLabel: entry.heroText
                )
                .padding(1)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    TokenRemainHeadLogo(
                        claudeRemaining: 0,
                        codexRemaining: 0,
                        size: 30
                    )
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
                HStack(spacing: 6) {
                    TokenRemainHeadLogo(
                        claudeRemaining: entry.remainingPercent(for: .claude),
                        codexRemaining: entry.remainingPercent(for: .codex),
                        size: 30
                    )
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(TRL10n.t("overview.min_remaining"))
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundStyle(TRTheme.textDim)
                        Text(entry.heroText)
                            .font(.system(size: 15, design: .monospaced).monospacedDigit().weight(.bold))
                        WidgetRiskMark(risk: entry.risk)
                    }
                    .frame(width: 38, alignment: .leading)

                    Rectangle()
                        .fill(TRTheme.border)
                        .frame(width: 1, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(entry.providers) { line in
                            HStack(spacing: 3) {
                                ProviderGlyph(provider: line.provider, size: 8)
                                SegmentBar(
                                    remainingPercent: line.remainingPercent,
                                    accent: TRTheme.accent(for: line.provider),
                                    segments: 8,
                                    height: 2.5
                                )
                                Text(UsageFormatting.percent(line.remainingPercent.rounded()))
                                    .font(.system(size: 8, design: .monospaced).monospacedDigit())
                                    .frame(width: 27, alignment: .trailing)
                            }
                        }
                        Spacer(minLength: 0)
                        if let reset = entry.soonestReset {
                            HStack(spacing: 3) {
                                PixelCheck(
                                    entry.willLastUntilReset ? .checked : .warn,
                                    size: 6,
                                    accent: paceColor(lasts: entry.willLastUntilReset)
                                )
                                Text(reset, style: .timer)
                                    .font(.system(size: 8, design: .monospaced).monospacedDigit())
                                    .foregroundStyle(TRTheme.cyan)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    TokenRemainHeadLogo(
                        claudeRemaining: 0,
                        codexRemaining: 0,
                        size: 24
                    )
                        .accessibilityHidden(true)
                    Text(entry.paceLine)
                        .font(.system(size: 12, design: .monospaced))
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilitySummary)
    }
}
