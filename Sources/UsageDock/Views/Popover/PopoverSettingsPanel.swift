import SwiftUI

/// Popup settings embedded in the surface they configure, so appearance
/// changes can be judged against the real desktop and actual widget content.
struct PopoverSettingsPanel: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var preferences: PreferencesStore
    let onOpenDashboard: (DashboardSection) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 12, weight: .semibold))
                    .usageDockAdaptiveForeground(.secondary)
                    .accessibilityHidden(true)

                Text(L10n.text("settings.popover_appearance"))
                    .font(.system(size: 13, weight: .semibold))
                    .usageDockAdaptiveForeground(.primary)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .usageDockAdaptiveForeground(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().stroke(DashboardTheme.border, lineWidth: 1))
                .help(L10n.text("action.close"))
                .accessibilityLabel(L10n.text("action.close"))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("settings.popover_glass_style"))
                    .font(.system(size: 10, weight: .medium))
                    .usageDockAdaptiveForeground(.muted)

                glassStyleControl
            }

            Divider().usageDockPopoverSeparator()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.text("settings.popover_background_opacity"))
                        .font(.system(size: 10, weight: .medium))
                        .usageDockAdaptiveForeground(.muted)

                    Spacer()

                    Text(opacityLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .usageDockAdaptiveForeground(.primary)
                        .frame(width: 42, alignment: .trailing)
                }

                Slider(
                    value: opacityBinding,
                    in: PreferencesStore.popoverBackgroundOpacityRange
                )
                .tint(DashboardTheme.violet)
                .accessibilityLabel(L10n.text("settings.popover_background_opacity"))
                .accessibilityHint(L10n.text("settings.popover_background_opacity_hint"))
                .accessibilityValue(opacityLabel)

                HStack {
                    Text(L10n.text("settings.popover_more_transparent"))
                    Spacer()
                    Text(L10n.text("settings.popover_more_opaque"))
                }
                .font(.system(size: 9))
                .usageDockAdaptiveForeground(.muted)
            }

            Divider().usageDockPopoverSeparator()

            HStack {
                Text(L10n.text("action.launch_at_login"))
                    .font(.system(size: 11, weight: .medium))
                    .usageDockAdaptiveForeground(.secondary)

                Spacer()

                Toggle(L10n.text("action.launch_at_login"), isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DashboardTheme.violet)
            }

            HStack(spacing: 8) {
                settingsAction(
                    L10n.text("action.open_dashboard_settings"),
                    systemImage: "slider.horizontal.3"
                ) {
                    onOpenDashboard(.settings)
                }

                settingsAction(
                    L10n.text("action.restart_app"),
                    systemImage: "arrow.clockwise"
                ) {
                    launchAtLogin.restart()
                }
            }
        }
        .padding(13)
        // Keep the dynamically inserted editor out of Liquid Glass sampling.
        // On macOS 26, inserting native Slider/SegmentedControl hosts into a
        // live GlassEffectContainer while the panel resizes can recurse through
        // MaterialProviderBox and terminate the process. The popup around this
        // editor remains the real live preview; this stable utility surface
        // exists only to keep its controls readable and crash-free.
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DashboardTheme.surface.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(DashboardTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    /// Two-chip style switch matching the Dashboard's brand-violet selection
    /// pill. Also sidesteps the hosted AppKit segmented control entirely —
    /// the panel keeps no native control hosts except the slider.
    private var glassStyleControl: some View {
        HStack(spacing: 3) {
            glassStyleChip(.frosted, L10n.text("settings.popover_glass_frosted"))
            glassStyleChip(.clear, L10n.text("settings.popover_glass_clear"))
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(DashboardTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("settings.popover_glass_style"))
        .accessibilityHint(L10n.text("settings.popover_glass_style_hint"))
    }

    private func glassStyleChip(_ style: PopoverGlassStyle, _ title: String) -> some View {
        let isSelected = preferences.popoverGlassStyle == style
        return Button {
            glassStyleBinding.wrappedValue = style
        } label: {
            Text(title)
                // White on the violet capsule: the Dashboard's selection
                // convention (sidebar rows, tab pills).
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(
                    isSelected
                        ? Color.white
                        : UsageDockPopoverAppearance.foregroundColor(
                            .secondary,
                            glassStyle: preferences.popoverGlassStyle
                        )
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? DashboardTheme.violet : Color.clear)
        )
        .animation(.easeInOut(duration: 0.16), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var glassStyleBinding: Binding<PopoverGlassStyle> {
        Binding(
            get: { preferences.popoverGlassStyle },
            set: { style in
                // The macOS 26 segmented control performs its action while
                // SwiftUI is still reconciling the hosted AppKit view. Publish
                // on the next main-loop turn so every glass subscriber updates
                // after that reconciliation instead of during it.
                DispatchQueue.main.async {
                    preferences.setPopoverGlassStyle(style)
                }
            }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { preferences.popoverBackgroundOpacity },
            set: { opacity in
                // Continuous slider (a stepped one draws tick dots the popup's
                // design has nowhere else); keep the stored 2% granularity.
                let rounded = (opacity / 0.02).rounded() * 0.02
                DispatchQueue.main.async {
                    preferences.setPopoverBackgroundOpacity(rounded)
                }
            }
        )
    }

    private var opacityLabel: String {
        "\(Int((preferences.popoverBackgroundOpacity * 100).rounded()))%"
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private func settingsAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        // Mirrors the footer command chips (11pt label, radius 9 — the
        // control tier of the shell 14 → card 13 → control 9 ladder), minus
        // the glass this panel deliberately avoids.
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .usageDockAdaptiveForeground(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(DashboardTheme.border, lineWidth: 1)
        )
    }
}
