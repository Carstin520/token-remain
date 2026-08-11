import AppKit
import SwiftUI

/// Popover footer: primary "Open Dashboard" link plus a compact settings menu
/// and Quit. The menu keeps every legacy action reachable from the menu bar —
/// launch-at-login, restart and Dashboard settings — matching the V2 layout
/// without crowding the popover.
///
/// The three actions are seated on their own compact glass surfaces rather than
/// left as bare labels. At low popup opacity bare labels read as text lying on
/// the desktop with no affordance; grouping them in one `GlassEffectContainer`
/// makes them a command area that follows the selected Clear/Frosted style,
/// while staying far lighter than a full-width card would be.
struct PopoverFooter: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    let onOpenDashboard: (DashboardSection) -> Void

    var body: some View {
        UsageDockGlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    onOpenDashboard(.overview)
                } label: {
                    Text(L10n.text("action.open_dashboard"))
                        .font(.system(size: 12, weight: .semibold))
                        .usageDockAdaptiveForeground(.primary)
                        .commandLabelPadding()
                }
                .buttonStyle(.plain)
                .commandSurface()
                .help(L10n.text("action.open_dashboard_help"))

                Spacer(minLength: 8)

                Menu {
                    Toggle(L10n.text("action.launch_at_login"), isOn: launchAtLoginBinding)
                    Divider()
                    Button(L10n.text("action.open_dashboard_settings")) { onOpenDashboard(.settings) }
                    Button(L10n.text("action.restart_app")) { launchAtLogin.restart() }
                } label: {
                    Text(L10n.text("action.settings"))
                        .font(.system(size: 11))
                        .usageDockAdaptiveForeground(.secondary)
                        .commandLabelPadding()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .usageDockAdaptiveTint(.secondary)
                .commandSurface()
                .accessibilityLabel(L10n.text("action.settings"))

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text(L10n.text("action.quit"))
                        .font(.system(size: 11))
                        .usageDockAdaptiveForeground(.secondary)
                        .commandLabelPadding()
                }
                .buttonStyle(.plain)
                .commandSurface()
                .help(L10n.text("action.quit_app"))
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }
}

private extension View {
    /// Padding lives on the label so the glass surface measures the full hit
    /// target, and so hover/press feedback never moves the text.
    func commandLabelPadding() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }

    /// Interactive glass at the smallest radius in the popup's corner set
    /// (shell 14 → card 13 → control 9). `clear` fallbacks keep the macOS 14/15
    /// popover on its existing flat text row instead of gaining three chips.
    func commandSurface() -> some View {
        usageDockGlassSurface(
            cornerRadius: 9,
            interactive: true,
            fallbackBackground: .clear,
            fallbackBorder: .clear
        )
    }
}
