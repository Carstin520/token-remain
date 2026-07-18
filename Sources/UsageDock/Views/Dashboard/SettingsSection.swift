import AppKit
import SwiftUI

/// Dashboard Settings: the fuller home for the popover's legacy actions —
/// launch-at-login, manual refresh, restart, quit — plus about / privacy info.
/// Every control is wired to the same live objects as the popover.
struct SettingsSection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager

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
                    .tint(DashboardTheme.codex)

                    if let error = launchAtLogin.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

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
                            Label("重启 UsageDock", systemImage: "arrow.clockwise.circle")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            Label("退出", systemImage: "power")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(title: "关于")
                    InfoRow(label: "版本", value: appVersion)
                    InfoRow(label: "数据", value: "全部留在本机")
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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "UsageDock \($0)" } ?? "UsageDock"
    }
}
