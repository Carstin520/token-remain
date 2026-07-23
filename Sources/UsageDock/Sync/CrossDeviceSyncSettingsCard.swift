#if TOKENREMAIN_CLOUD_SYNC
import SwiftUI

struct CrossDeviceSyncSettingsCard: View {
    @ObservedObject private var sync = CrossDeviceSyncController.shared
    @State private var showsPreview = false
    @State private var confirmsDeletion = false

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(title: "跨设备同步", subtitle: "Mac → iCloud 私有数据库 → iPhone")

                Toggle(isOn: enabledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("加密同步到我的 Apple 设备")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DashboardTheme.text)
                        Text("默认关闭；provider 凭证、账号、路径、错误原文与 Token 明细永不上传")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
                .tint(DashboardTheme.violet)

                Toggle(isOn: usageHistoryBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("同步每日 Token / 费用历史")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DashboardTheme.text)
                        Text("独立授权；最多 30 天，仅 Claude / Codex 的按日聚合值")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
                .tint(DashboardTheme.violet)
                .disabled(!sync.isEnabled)

                Label(statusText, systemImage: statusIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)

                DisclosureGroup(isExpanded: $showsPreview) {
                    VStack(alignment: .leading, spacing: 7) {
                        if sync.previewProviders.isEmpty {
                            Text("Mac 尚无可同步的额度快照")
                                .foregroundStyle(DashboardTheme.secondaryText)
                        } else {
                            ForEach(sync.previewProviders) { provider in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(provider.id)
                                        .foregroundStyle(DashboardTheme.text)
                                    Spacer()
                                    Text(windowSummary(provider.windows))
                                        .foregroundStyle(DashboardTheme.secondaryText)
                                }
                            }
                        }
                        if sync.syncUsageHistoryEnabled {
                            HStack {
                                Text("每日用量历史")
                                    .foregroundStyle(DashboardTheme.text)
                                Spacer()
                                Text("\(sync.previewHistoryDays) 天 · Claude / Codex")
                                    .foregroundStyle(DashboardTheme.secondaryText)
                            }
                        }
                        Text("预览即完整白名单：所有已启用额度来源的 provider ID、百分比、窗口、重置时间、采集时间和安全套餐标签；历史只含日期、Claude/Codex 每日 Token 和估算费用。无账号、提示词、项目、会话或逐请求明细。")
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("查看将要同步的数据")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DashboardTheme.text)
                }

                Divider().overlay(DashboardTheme.border)

                HStack(spacing: 10) {
                    if sync.state == .anotherMacIsPrimary {
                        Button("改用这台 Mac", role: .destructive) {
                            sync.takeOverAsPrimaryMac()
                        }
                    } else {
                        Button("立即安全同步") { sync.uploadNow() }
                            .disabled(!sync.isEnabled || sync.previewProviders.isEmpty)
                    }
                    Spacer()
                    Button("从 iCloud 删除并断开", role: .destructive) {
                        confirmsDeletion = true
                    }
                }
                .usageDockActionButtonStyle()

                Text("CloudKit 记录仍使用 AES-256-GCM 应用层加密；TokenRemain 自建服务器不参与此数据链路。")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("删除跨设备同步数据？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) {}
            Button("删除并断开", role: .destructive) {
                Task { await sync.deleteCloudDataAndDisconnect() }
            }
        } message: {
            Text("将删除 TokenRemain 的 CloudKit 私有同步区和专用同步密钥。Mac 上的 provider 凭证及本地额度不会被删除。")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { sync.isEnabled }, set: sync.setEnabled)
    }

    private var usageHistoryBinding: Binding<Bool> {
        Binding(get: { sync.syncUsageHistoryEnabled }, set: sync.setUsageHistoryEnabled)
    }

    private var statusText: String {
        switch sync.state {
        case .off: return "同步已关闭"
        case .needsSignedCapabilities: return "当前构建尚未获得 CloudKit / 同步钥匙串签名权限"
        case .waitingForMacData: return "等待 Mac 产生第一份额度快照"
        case .checkingICloud: return "正在检查 iCloud 账户"
        case .anotherMacIsPrimary: return "iCloud 已有主数据 Mac；接管后 iPhone 会再次要求确认"
        case .uploading: return "正在加密并上传最新快照"
        case .synced(let date): return "上次安全同步：\(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let failure): return failureText(failure)
        }
    }

    private var statusIcon: String {
        switch sync.state {
        case .synced: "checkmark.shield.fill"
        case .uploading, .checkingICloud: "arrow.triangle.2.circlepath.icloud"
        case .anotherMacIsPrimary: "desktopcomputer.trianglebadge.exclamationmark"
        case .failed, .needsSignedCapabilities: "exclamationmark.triangle.fill"
        case .off, .waitingForMacData: "lock.icloud"
        }
    }

    private var statusColor: Color {
        switch sync.state {
        case .synced: DashboardTheme.success
        case .failed, .needsSignedCapabilities, .anotherMacIsPrimary: DashboardTheme.warning
        default: DashboardTheme.secondaryText
        }
    }

    private func failureText(_ failure: CrossDeviceSyncController.Failure) -> String {
        switch failure {
        case .iCloudUnavailable: "iCloud 不可用；请确认已登录同一 Apple 账户"
        case .keychainUnavailable: "同步钥匙串暂不可用；不会上传未加密数据"
        case .networkUnavailable: "网络不可用；恢复后会重试最新快照"
        case .serviceUnavailable: "iCloud 暂时繁忙；稍后自动重试"
        case .encryptionFailed: "快照校验或加密失败；旧数据不会被覆盖"
        case .unknown: "同步暂不可用；旧数据不会被覆盖"
        }
    }

    private func windowSummary(_ windows: [CrossDeviceSyncController.PreviewProvider.Window]) -> String {
        windows.map { window in
            let value = String(format: "%.0f%%", window.usedPercent)
            return window.windowMinutes == 0 ? value : "\(value) / \(window.windowMinutes) 分钟"
        }.joined(separator: " · ")
    }
}
#endif
