import AppKit
import SwiftUI

/// The menu-bar popover, rebuilt to the approved V2 dark layout: title + update
/// time + refresh, a risk-first summary, one card per provider, today's local
/// stats, and a footer that opens the Dashboard and hosts the legacy actions.
struct UsageMenuView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    /// Opens (and fronts) the Dashboard window on a given section.
    let onOpenDashboard: (DashboardSection) -> Void

    @State private var measuredHeight: CGFloat = 700

    private var insights: UsageInsights {
        UsageInsights(claude: store.claude, codex: store.codex, daily: store.daily)
    }

    /// Cap the popover to the visible screen so long content scrolls instead of
    /// being clipped by the menu bar.
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 48
    }

    private var combinedError: String? {
        [store.errorMessage, launchAtLogin.errorMessage]
            .compactMap { $0 }
            .joined(separator: "\n")
            .nonEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                RiskStrip(
                    risk: insights.riskLevel,
                    minRemainingPercent: insights.minRemainingPercent
                )

                QuotaCard(provider: .claude, quota: store.claude)
                QuotaCard(provider: .codex, quota: store.codex)

                LocalUsageCard(insights: insights)

                if let combinedError {
                    Label(combinedError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(DashboardTheme.border).padding(.top, 1)

                PopoverFooter(launchAtLogin: launchAtLogin, onOpenDashboard: onOpenDashboard)
            }
            .padding(16)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PopoverHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(width: 380)
        .frame(height: min(measuredHeight, maxHeight))
        .background(DashboardTheme.canvas)
        .preferredColorScheme(.dark)
        .onPreferenceChange(PopoverHeightKey.self) { measuredHeight = $0 }
        .task { store.start() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("UsageDock")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(DashboardTheme.text)
                Text(updatedSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            Spacer()
            refreshButton
        }
    }

    private var updatedSubtitle: String {
        if let updated = insights.lastUpdated {
            return "更新于 \(updated.formatted(date: .omitted, time: .shortened)) · 数据留在本机"
        }
        return "正在读取用量 · 数据留在本机"
    }

    private var refreshButton: some View {
        Button {
            Task { await store.refresh(forceCCUsage: true, forceClaude: true) }
        } label: {
            ZStack {
                Circle()
                    .fill(DashboardTheme.surface2)
                    .overlay(Circle().strokeBorder(DashboardTheme.border, lineWidth: 1))
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DashboardTheme.text)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .disabled(store.isRefreshing)
        .help("立即刷新 ccusage、Codex 与 Claude 官方额度")
        .accessibilityLabel("刷新用量")
    }
}

/// Reports the intrinsic content height so the popover can size to its content
/// yet cap at the screen height.
private struct PopoverHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
