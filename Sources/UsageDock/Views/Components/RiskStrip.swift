import SwiftUI

/// Risk-first summary banner: the product's headline signal. Tint and copy come
/// from `RiskLevel`; the trailing value shows the scarcest remaining quota.
struct RiskStrip: View {
    let risk: RiskLevel
    let minRemainingPercent: Double?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("当前额度风险")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.mutedText)
                Text("\(risk.badge) · \(risk.headline)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(risk.tint)
            }
            Spacer(minLength: 8)
            if let minRemainingPercent {
                Text("最低剩余 \(UsageFormatting.percent(minRemainingPercent))")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DashboardTheme.text)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(risk.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(risk.tint.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前额度风险 \(risk.badge)，\(risk.headline)")
        .accessibilityValue(minRemainingPercent.map { "最低剩余 \(UsageFormatting.percent($0))" } ?? "")
    }
}
