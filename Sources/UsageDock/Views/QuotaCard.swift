import SwiftUI

/// Full provider quota card: brand row + plan pill, then one row per official
/// window (remaining %, progress bar, reset label). Shown in the popover and in
/// the Dashboard's Limits section. Renders a waiting state before data arrives.
struct QuotaCard: View {
    let provider: ProviderQuota.Provider
    let quota: ProviderQuota?

    var body: some View {
        DashboardCard(padding: 13) {
            VStack(alignment: .leading, spacing: 11) {
                header

                if let quota {
                    QuotaWindowRow(window: quota.primary, provider: provider)
                    if let secondary = quota.secondary {
                        Divider().overlay(DashboardTheme.border)
                        QuotaWindowRow(window: secondary, provider: provider)
                    }
                    Text("额度更新于 \(quota.capturedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardTheme.mutedText)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取官方额度…")
                            .font(.system(size: 12))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandIcon(provider: provider)
                .foregroundStyle(DashboardTheme.text)
                .frame(width: 20, height: 20)
            Text(provider == .claude ? "Claude" : "Codex")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DashboardTheme.text)
            Spacer()
            if let plan = quota?.planName, !plan.isEmpty {
                TagPill(text: plan)
            }
        }
    }
}

/// A single quota window inside a `QuotaCard`.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    let provider: ProviderQuota.Provider

    private var remainingPercent: Double {
        min(100, max(0, 100 - window.usedPercent))
    }

    private var fill: LinearGradient {
        DashboardTheme.fill(for: provider)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageFormatting.windowName(minutes: window.windowMinutes) + "窗口")
                        .font(.system(size: 13))
                        .foregroundStyle(DashboardTheme.secondaryText)
                    Spacer()
                    Text("剩余 \(UsageFormatting.percent(remainingPercent))")
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(DashboardTheme.text)
                }

                UsageProgressBar(value: remainingPercent / 100, fill: fill)

                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                    if let resetsAt = window.resetsAt {
                        Text(UsageFormatting.resetDescription(to: resetsAt, now: context.date))
                            .monospacedDigit()
                    } else {
                        Text("下次重置时间待官方提供")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(DashboardTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider == .claude ? "Claude" : "Codex") \(UsageFormatting.windowName(minutes: window.windowMinutes))窗口")
        .accessibilityValue("剩余 \(UsageFormatting.percent(remainingPercent))")
    }
}
