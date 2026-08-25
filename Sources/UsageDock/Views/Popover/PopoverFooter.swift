import AppKit
import SwiftUI

/// Popover footer: primary "Open Dashboard" link, inline popup settings and
/// Quit. The expandable panel keeps launch-at-login, restart and Dashboard
/// settings reachable while appearance changes remain visible in context.
///
/// The three actions are seated on their own compact glass surfaces rather than
/// left as bare labels. At low popup opacity bare labels read as text lying on
/// the desktop with no affordance; grouping them in one `GlassEffectContainer`
/// makes them a command area that follows the selected Clear/Frosted style,
/// while staying far lighter than a full-width card would be.
struct PopoverFooter: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var preferences: PreferencesStore = .shared
    let onOpenDashboard: (DashboardSection) -> Void
    /// Owned by the popup root: the editor floats above the whole glass
    /// container, so presentation cannot live inside this footer.
    @Binding var isSettingsPresented: Bool

    var body: some View {
        VStack(spacing: 10) {
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

                    Button {
                        isSettingsPresented.toggle()
                    } label: {
                        Text(L10n.text("action.settings"))
                            .font(.system(size: 11))
                            .usageDockAdaptiveForeground(.secondary)
                            .commandLabelPadding()
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .commandSurface()
                    .accessibilityLabel(L10n.text("action.settings"))
                    .accessibilityAddTraits(isSettingsPresented ? .isSelected : [])

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
        .onAppear {
#if DEBUG
            // Visual-QA companion to the app's existing `--open-popover`
            // launch hook. It avoids UI automation having to activate this
            // intentionally nonactivating panel before it can inspect the
            // live editor.
            if ProcessInfo.processInfo.arguments.contains("--open-popup-settings") {
                isSettingsPresented = true
            }
#endif
        }
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
            fallbackBackground: Color.clear,
            fallbackBorder: Color.clear
        )
    }
}
