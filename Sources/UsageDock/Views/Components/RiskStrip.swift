import SwiftUI

/// Risk-first summary banner: the product's headline signal. Tint and copy come
/// from live remaining quota plus the current-window pace projection. When a
/// window is projected to run out before reset, the banner names that window,
/// when it runs out and when it resets; otherwise the second line names the
/// service with the least quota left.
struct RiskStrip: View {
    let insights: UsageInsights

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let risk = insights.riskLevel(at: context.date)

            HStack(spacing: 10) {
                PixelBadge(text: risk.badge, color: risk.tint, filled: risk == .high)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(at: context.date))
                        .numericFont(13, .semibold)
                        .usageDockAdaptiveForeground(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    if let detail = detail(at: context.date) {
                        Text(detail)
                            .numericFont(11, .medium)
                            .usageDockAdaptiveForeground(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            // Localize semantic color to the badge. A colored card face or
            // outline competes with the meters and makes medium risk feel like
            // a persistent alert rather than a decision summary.
            // Colors omitted on purpose: the card follows the environment
            // palette, so it tracks the Dashboard's background-lightness
            // preference and stays dark inside the popup.
            .usageDockGlassSurface(cornerRadius: 13)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.format(
                "risk.accessibility_summary",
                risk.badge,
                headline(at: context.date)
            ))
            .accessibilityValue(detail(at: context.date) ?? "")
        }
    }

    private func headline(at now: Date) -> String {
        guard let assessment = insights.paceAssessment(at: now),
              let runOutAt = assessment.pace.estimatedRunOutAt
        else { return insights.decisionHeadline(at: now) }
        if assessment.pace.isExhausted {
            let window = assessment.window
            return "\(window.displayName) \(UsageFormatting.windowFullName(minutes: window.windowMinutes)) · \(L10n.text("pace.exhausted"))"
        }
        return L10n.format(
            "risk.headline.window_runout",
            assessment.window.displayName,
            UsageFormatting.windowFullName(minutes: assessment.window.windowMinutes),
            UsageFormatting.durationUntil(runOutAt, now: now)
        )
    }

    /// `8.4% ahead · Resets Tue 12:58` for a projected run-out; otherwise
    /// `Claude 52% remaining` for the scarcest window.
    private func detail(at now: Date) -> String? {
        if let assessment = insights.paceAssessment(at: now) {
            if assessment.pace.isExhausted {
                return assessment.window.resetsAt.map { UsageFormatting.resetDescription(to: $0, now: now) }
            }
            let ahead = L10n.format("pace.deficit", UsageFormatting.percent(abs(assessment.pace.deltaPercent)))
            guard let reset = assessment.window.resetsAt else { return ahead }
            return "\(ahead) · \(UsageFormatting.resetDescription(to: reset, now: now))"
        }
        return insights.constrainingWindow.map {
            L10n.format(
                "risk.provider_remaining",
                $0.displayName,
                UsageFormatting.percent($0.remainingPercent)
            )
        }
    }
}
