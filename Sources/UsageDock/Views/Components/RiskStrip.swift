import SwiftUI

/// Risk-first summary banner: the product's headline signal. Tint and copy come
/// from live remaining quota plus the current-window pace projection. The
/// trailing value names the service that currently constrains the user.
struct RiskStrip: View {
    let insights: UsageInsights

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let risk = insights.riskLevel(at: context.date)

            HStack(spacing: 10) {
                PixelBadge(text: risk.badge, color: risk.tint, filled: risk == .high)

                VStack(alignment: .leading, spacing: 2) {
                    Text(insights.decisionHeadline(at: context.date))
                        .font(.system(size: 13, weight: .semibold))
                        .usageDockAdaptiveForeground(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    if let window = insights.constrainingWindow {
                        Text(L10n.format(
                            "risk.provider_remaining",
                            window.displayName,
                            UsageFormatting.percent(window.remainingPercent)
                        ))
                            .numericFont(10, .medium)
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
            .usageDockGlassSurface(
                cornerRadius: 13,
                fallbackBackground: DashboardTheme.surface,
                fallbackBorder: DashboardTheme.border
            )
            .pixelTicks(cornerRadius: 13)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.format(
                "risk.accessibility_summary",
                risk.badge,
                insights.decisionHeadline(at: context.date)
            ))
            .accessibilityValue(
                insights.constrainingWindow.map {
                    L10n.format(
                        "risk.provider_remaining",
                        $0.displayName,
                        UsageFormatting.percent($0.remainingPercent)
                    )
                } ?? ""
            )
        }
    }
}
