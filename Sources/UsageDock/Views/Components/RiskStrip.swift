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
                        .foregroundStyle(DashboardTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    if let window = insights.constrainingWindow {
                        Text("\(window.provider.displayName) 剩余 \(UsageFormatting.percent(window.remainingPercent))")
                            .numericFont(10, .medium)
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            // The semantic signal lives in the badge + border; the card face
            // stays near-neutral so one banner doesn't wash the whole popover
            // in amber/red.
            .usageDockGlassSurface(
                cornerRadius: 13,
                tint: risk.tint.opacity(0.07),
                fallbackBackground: risk.tint.opacity(0.05),
                fallbackBorder: risk.tint.opacity(0.28)
            )
            .pixelTicks(cornerRadius: 13, color: risk.tint.opacity(0.35))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("当前使用判断 \(risk.badge)，\(insights.decisionHeadline(at: context.date))")
            .accessibilityValue(
                insights.constrainingWindow.map {
                    "\($0.provider.displayName) 剩余 \(UsageFormatting.percent($0.remainingPercent))"
                } ?? ""
            )
        }
    }
}
