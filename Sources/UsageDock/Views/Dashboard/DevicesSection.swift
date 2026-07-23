import Foundation
import SwiftUI

/// Dashboard Devices: live facts about the publishing Mac and its private
/// CloudKit delivery path. This intentionally reports sync endpoints rather
/// than inventing a device inventory CloudKit does not expose to the app.
struct DevicesSection: View {
    let insights: UsageInsights
#if TOKENREMAIN_CLOUD_SYNC
    @ObservedObject private var sync = CrossDeviceSyncController.shared
#endif

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
#if TOKENREMAIN_CLOUD_SYNC
                DashboardCard {
                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeader(title: "CloudKit 私有同步", subtitle: "这台 Mac → Apple 设备") {
                            StatusDotLabel(color: syncStatusColor, text: syncStatusText, bold: true)
                        }
                        InfoRow(label: "数据库", value: "iCloud 私有数据库")
                        InfoRow(label: "当前发布来源", value: "\(sync.previewProviders.count) 个")
                        InfoRow(label: "变更上传", value: "约 4 秒后")
                        InfoRow(label: "保活同步", value: "每 15 分钟")
                        if let uploaded = sync.lastUploadedAt {
                            InfoRow(
                                label: "最近上传",
                                value: uploaded.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                        Text("仅同步额度百分比、窗口、重置时间、采集时间、状态和安全套餐标签；内容经应用层加密后写入当前 iCloud 账户的私有库。")
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)

                DashboardCard {
                    VStack(alignment: .leading, spacing: 14) {
                        PanelHeader(title: "Apple 设备接收端", subtitle: "由系统 iCloud 账户关联")
                        RoadmapList(items: [
                            "iPhone 前台每 45 秒校验最新快照",
                            "CloudKit 静默推送触发低延迟拉取",
                            "主屏 / 锁屏 Widget 与 Apple Watch 读取已验证快照",
                            "无需 TokenRemain 登录或 Sign in with Apple"
                        ])
                        Text("后台刷新时机由 iOS 调度，不能承诺固定分钟级周期；设备清单需未来增加匿名接收回执后才能准确展示。")
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
#else
                DashboardCard {
                    EmptyStateView(
                        icon: "lock.icloud",
                        title: "当前构建未启用同步权限",
                        message: "请安装带 CloudKit 与同步钥匙串签名权限的 TokenRemain 构建，设备页才会显示真实私有同步状态。"
                    )
                }
#endif
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
        var sources = insights.quotas.map { $0.provider.displayName }
        if insights.daily != nil { sources.append("ccusage") }
        return sources.isEmpty ? "暂无" : sources.joined(separator: " · ")
    }

#if TOKENREMAIN_CLOUD_SYNC
    private var syncStatusText: String {
        switch sync.state {
        case .off: return "已关闭"
        case .needsSignedCapabilities: return "缺少签名权限"
        case .waitingForMacData: return "等待额度"
        case .checkingICloud: return "检查 iCloud"
        case .anotherMacIsPrimary: return "其他 Mac 为主设备"
        case .uploading: return "上传中"
        case .synced: return "已同步"
        case .failed: return "同步异常"
        }
    }

    private var syncStatusColor: Color {
        switch sync.state {
        case .synced: return DashboardTheme.success
        case .failed, .needsSignedCapabilities, .anotherMacIsPrimary: return DashboardTheme.warning
        default: return DashboardTheme.secondaryText
        }
    }
#endif
}

private extension OperatingSystemVersion {
    var shortString: String {
        patchVersion == 0
            ? "\(majorVersion).\(minorVersion)"
            : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}
