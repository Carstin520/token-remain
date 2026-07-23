import AppKit
import SwiftUI

/// 会自动换行排列的 provider 开关胶囊(菜单栏自选用):点亮即上菜单栏。
private struct FlowToggleRow: View {
    let providers: [ProviderQuota.Provider]
    let isOn: (ProviderQuota.Provider) -> Bool
    let toggle: (ProviderQuota.Provider) -> Void

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(providers, id: \.self) { provider in
                let active = isOn(provider)
                Button {
                    toggle(provider)
                } label: {
                    HStack(spacing: 6) {
                        BrandIcon(provider: provider)
                            .foregroundStyle(DashboardTheme.text)
                            .frame(width: 14, height: 14)
                        Text(provider.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DashboardTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                            .layoutPriority(1)
                        Spacer(minLength: 2)
                        Image(systemName: active ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(active ? DashboardTheme.success : DashboardTheme.mutedText)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(active ? DashboardTheme.surface3 : DashboardTheme.surface2)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(provider.displayName)
                .accessibilityValue(active ? "已显示在菜单栏" : "未显示在菜单栏")
            }
        }
    }
}

/// Dashboard Settings: the fuller home for the popover's legacy actions —
/// launch-at-login, manual refresh, restart, quit — plus about / privacy info.
/// Every control is wired to the same live objects as the popover.
struct SettingsSection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var preferences: PreferencesStore = .shared
    @ObservedObject var tracked: TrackedProvidersStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.settings.title,
                subtitle: DashboardSection.settings.subtitle
            )

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: "通用")
                    Toggle(isOn: launchAtLoginBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("登录时自动启动")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DashboardTheme.text)
                            Text("使用 macOS 原生登录项管理")
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardTheme.secondaryText)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DashboardTheme.violet)

                    if let error = launchAtLogin.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 14) {
                    PanelHeader(title: "显示与刷新")

                    // 菜单栏内容自选:任意追踪中的 provider 都可上菜单栏。
                    VStack(alignment: .leading, spacing: 6) {
                        Text("菜单栏显示")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DashboardTheme.text)
                        Text("勾选要常驻菜单栏文字的应用；建议不超过 3 项以免过宽。全部关闭时显示 “TR”。")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                        FlowToggleRow(
                            providers: tracked.enabledOrdered,
                            isOn: { preferences.isInMenuBar($0) },
                            toggle: { preferences.toggleMenuBar($0) }
                        )
                    }

                    Divider().overlay(DashboardTheme.border)

                    // 直查刷新频率。
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("额度刷新频率")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DashboardTheme.text)
                            Text("各服务端接口的自动直查间隔；“仅手动”时只在点刷新按钮时请求")
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardTheme.secondaryText)
                        }
                        Spacer()
                        Picker("", selection: refreshBinding) {
                            ForEach(PreferencesStore.refreshChoices, id: \.self) { minutes in
                                Text(minutes == 0 ? "仅手动" : "\(minutes) 分钟").tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }

                    Divider().overlay(DashboardTheme.border)

                    // 桌面浮窗。
                    Toggle(isOn: floatingBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("桌面浮窗")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DashboardTheme.text)
                            Text("置顶的挂件面板,跨桌面空间常驻;可整窗拖动,位置自动记忆")
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardTheme.secondaryText)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DashboardTheme.violet)
                }
            }

#if TOKENREMAIN_CLOUD_SYNC
            CrossDeviceSyncSettingsCard()
#endif

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: "操作")
                    HStack(spacing: 10) {
                        Button {
                            Task { await store.refresh(forceCCUsage: true, forceClaude: true) }
                        } label: {
                            Label(store.isRefreshing ? "刷新中…" : "立即刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)

                        Button {
                            launchAtLogin.restart()
                        } label: {
                            Label("重启 TokenRemain", systemImage: "arrow.clockwise.circle")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            Label("退出", systemImage: "power")
                        }
                    }
                    .usageDockActionButtonStyle()
                    .controlSize(.large)
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(title: "关于")
                    InfoRow(label: "版本", value: appVersion)
                    InfoRow(label: "数据", value: "本地优先 · 可选 iCloud 私有加密同步")
                    HStack {
                        Text("统计来源")
                            .font(.system(size: 12))
                            .foregroundStyle(DashboardTheme.secondaryText)
                        Spacer()
                        Link("ccusage.com", destination: URL(string: "https://ccusage.com/")!)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DashboardTheme.link)
                    }
                }
            }
        }
    }

    private var refreshBinding: Binding<Int> {
        Binding(
            get: { preferences.refreshMinutes },
            set: { preferences.setRefreshMinutes($0) }
        )
    }

    private var floatingBinding: Binding<Bool> {
        Binding(
            get: { preferences.floatingWidgetEnabled },
            set: { preferences.setFloatingWidgetEnabled($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "TokenRemain \($0)" } ?? "TokenRemain"
    }
}
