import Foundation
import SwiftUI

/// Dashboard Devices: real facts about the Mac being monitored today, and an
/// honest empty state for the cross-device experience that isn't built yet.
struct DevicesSection: View {
    let insights: UsageInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.devices.title,
                subtitle: DashboardSection.devices.subtitle
            )

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: "这台 Mac", subtitle: "当前受监测的设备") {
                        StatusDotLabel(color: DashboardTheme.success, text: "监测中", bold: true)
                    }
                    InfoRow(label: "设备名称", value: deviceName)
                    InfoRow(label: "系统版本", value: osVersion)
                    InfoRow(label: "活跃数据源", value: activeSourcesText)
                    if let updated = insights.lastUpdated {
                        InfoRow(label: "最近更新", value: updated.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                DashboardCard {
                    EmptyStateView(
                        icon: "laptopcomputer.and.iphone",
                        title: "跨设备同步即将到来",
                        message: "UsageDock 目前仅监测这台 Mac 上的本地数据。跨设备一览需要伴侣 App 与同步能力，尚未实现，因此不会显示其他并不存在的设备。"
                    )
                }
                .frame(maxWidth: .infinity)

                DashboardCard {
                    VStack(alignment: .leading, spacing: 14) {
                        PanelHeader(title: "规划中", subtitle: "跨设备方向")
                        RoadmapList(items: [
                            "iPhone 伴侣 App 一览额度",
                            "iCloud 跨设备安全同步",
                            "主屏 / 锁屏 WidgetKit 小组件",
                            "Apple Watch 快速查看"
                        ])
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var deviceName: String {
        Host.current().localizedName ?? "这台 Mac"
    }

    private var osVersion: String {
        "macOS " + ProcessInfo.processInfo.operatingSystemVersion.shortString
    }

    private var activeSourcesText: String {
        var sources: [String] = []
        if insights.claude != nil { sources.append("Claude") }
        if insights.codex != nil { sources.append("Codex") }
        if insights.daily != nil { sources.append("ccusage") }
        return sources.isEmpty ? "暂无" : sources.joined(separator: " · ")
    }
}

private extension OperatingSystemVersion {
    var shortString: String {
        patchVersion == 0
            ? "\(majorVersion).\(minorVersion)"
            : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}
