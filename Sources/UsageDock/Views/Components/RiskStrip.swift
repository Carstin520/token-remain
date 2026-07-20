import SwiftUI

/// Risk-first summary banner: the product's headline signal. Tint and copy come
/// from live remaining quota plus the current-window pace projection. The
/// trailing value names the service that currently constrains the user.
struct RiskStrip: View {
    let insights: UsageInsights

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let risk = insights.riskLevel(at: context.date)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PixelBadge(text: risk.badge, color: risk.tint, filled: risk == .high)
                    Text("当前使用判断")
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.mutedText)
                    Spacer(minLength: 8)
                    if let window = insights.constrainingWindow {
                        let provider = window.provider == .claude ? "Claude" : "Codex"
                        Text("\(provider) 剩余 \(UsageFormatting.percent(window.remainingPercent))")
                            .numericFont(12, .bold)
                            .foregroundStyle(DashboardTheme.text)
                    }
                }

                Text(insights.decisionHeadline(at: context.date))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .usageDockGlassSurface(
                cornerRadius: 13,
                tint: risk.tint.opacity(0.16),
                fallbackBackground: risk.tint.opacity(0.10),
                fallbackBorder: risk.tint.opacity(0.30)
            )
            .pixelTicks(cornerRadius: 13, color: risk.tint.opacity(0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("当前使用判断 \(risk.badge)，\(insights.decisionHeadline(at: context.date))")
            .accessibilityValue(
                insights.constrainingWindow.map {
                    let provider = $0.provider == .claude ? "Claude" : "Codex"
                    return "\(provider) 剩余 \(UsageFormatting.percent($0.remainingPercent))"
                } ?? ""
            )
        }
    }
}
