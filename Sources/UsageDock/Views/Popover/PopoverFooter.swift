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
                Text(L10n.text("action.open_dashboard"))
                    .font(.system(size: 12, weight: .semibold))
                    .usageDockAdaptiveForeground(.primary)
            }
            .buttonStyle(.plain)
            .help(L10n.text("action.open_dashboard_help"))

            Spacer()

            Menu {
                Toggle(L10n.text("action.launch_at_login"), isOn: launchAtLoginBinding)
                Divider()
                Button(L10n.text("action.open_dashboard_settings")) { onOpenDashboard(.settings) }
                Button(L10n.text("action.restart_app")) { launchAtLogin.restart() }
            } label: {
                Text(L10n.text("action.settings"))
                    .font(.system(size: 11))
                    .usageDockAdaptiveForeground(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .usageDockAdaptiveTint(.secondary)

            Text("·")
                .font(.system(size: 11))
                .usageDockAdaptiveForeground(.muted)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text(L10n.text("action.quit"))
                    .font(.system(size: 11))
                    .usageDockAdaptiveForeground(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.text("action.quit_app"))
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }
}
