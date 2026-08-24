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

                LiquidGlassSlider(
                    value: opacityBinding,
                    range: PreferencesStore.popoverBackgroundOpacityRange
                )
                .accessibilityElement()
                .accessibilityLabel(L10n.text("settings.popover_background_opacity"))
                .accessibilityHint(L10n.text("settings.popover_background_opacity_hint"))
                .accessibilityValue(opacityLabel)
                .accessibilityAdjustableAction { direction in
                    // 0.1 是存储粒度 0.02 的整数倍,十步走完全程。
                    let step = 0.1
                    let current = preferences.popoverBackgroundOpacity
                    switch direction {
                    case .increment:
                        opacityBinding.wrappedValue = min(current + step, PreferencesStore.popoverBackgroundOpacityRange.upperBound)
                    case .decrement:
                        opacityBinding.wrappedValue = max(current - step, PreferencesStore.popoverBackgroundOpacityRange.lowerBound)
                    @unknown default:
                        break
                    }
                }

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
        // MaterialProviderBox and terminate the process — which is why every
        // control in this panel is now drawn in pure SwiftUI, the slider
        // included. The popup around this editor remains the real live preview;
        // this stable utility surface exists only to keep its controls readable
        // and crash-free.
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
    /// the panel keeps no native control hosts at all.
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
}

/// 纯 SwiftUI 的液态玻璃滑块:5pt 细轨道 + 13pt 玻璃拇指,替代系统
/// Slider 的大号 AppKit 宿主。拇指的玻璃感是纯绘制的(透明白渐变 +
/// 上缘高光沿),不做真正的 glassEffect 背景采样——这个面板承诺
/// 停留在 Liquid Glass 采样之外(见 body 的 background 注释),
/// 材质在这里是视觉语言,不是渲染管线。
private struct LiquidGlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    /// 拖动期间拇指连续跟随光标;存储值仍按调用方 binding 的粒度量化,
    /// 松手后拇指落回量化位置。
    @State private var dragFraction: Double?

    private let trackHeight: CGFloat = 5
    private let thumbDiameter: CGFloat = 13

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - thumbDiameter)
            let fraction = dragFraction ?? storedFraction
            let thumbCenter = thumbDiameter / 2 + travel * fraction
            let isDragging = dragFraction != nil

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(DashboardTheme.border, lineWidth: 1)
                    )
                    .frame(height: trackHeight)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DashboardTheme.violetDim, DashboardTheme.violet],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackHeight, thumbCenter), height: trackHeight)
                    .shadow(
                        color: DashboardTheme.violet.opacity(isDragging ? 0.45 : 0.2),
                        radius: isDragging ? 5 : 2
                    )

                glassThumb(isDragging: isDragging)
                    .offset(x: thumbCenter - thumbDiameter / 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gestureValue in
                        let raw = (gestureValue.location.x - thumbDiameter / 2) / travel
                        let clamped = min(max(raw, 0), 1)
                        dragFraction = clamped
                        value = range.lowerBound
                            + (range.upperBound - range.lowerBound) * clamped
                    }
                    .onEnded { _ in dragFraction = nil }
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isDragging)
        }
        .frame(height: 20)
    }

    private var storedFraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func glassThumb(isDragging: Bool) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.38), Color.white.opacity(0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.65), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .frame(width: thumbDiameter, height: thumbDiameter)
            .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
            .scaleEffect(isDragging ? 1.25 : 1)
    }
}

private extension PopoverSettingsPanel {
    func settingsAction(
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
