import AppKit
import SwiftUI

/// Popover footer: primary "Open Dashboard" link plus a compact settings menu
/// and Quit. The menu keeps every legacy action reachable from the menu bar —
/// launch-at-login, restart and Dashboard settings — matching the V2 layout
/// without crowding the popover.
struct PopoverFooter: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    let onOpenDashboard: (DashboardSection) -> Void

    var body: some View {
        HStack {
            Button {
                onOpenDashboard(.overview)
            } label: {
                Text("打开 Dashboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DashboardTheme.link)
            }
            .buttonStyle(.plain)
            .help("打开独立的 UsageDock Dashboard 窗口")

            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.mutedText)

            Button {
                onOpenDashboard(.aiFeed)
            } label: {
                Text("AI Feed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DashboardTheme.link)
            }
            .buttonStyle(.plain)
            .help("查看 AI 领袖动态与重大更新")

            Spacer()

            Menu {
                Toggle("登录时自动启动", isOn: launchAtLoginBinding)
                Divider()
                Button("打开 Dashboard 设置") { onOpenDashboard(.settings) }
                Button("重启 UsageDock") { launchAtLogin.restart() }
            } label: {
                Text("设置")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.mutedText)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("退出")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("退出 UsageDock")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }
}
