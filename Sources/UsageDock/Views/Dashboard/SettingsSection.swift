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
                .accessibilityValue(active ? L10n.text("settings.menubar_shown") : L10n.text("settings.menubar_hidden"))
            }
        }
    }
}

/// A picture-first chooser: each option previews the exact menu-bar density
/// before the user applies it.
private struct MenuBarDisplayModePicker: View {
    let selectedMode: MenuBarDisplayMode
    let select: (MenuBarDisplayMode) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(MenuBarDisplayMode.allCases) { mode in
                let isSelected = mode == selectedMode
                Button {
                    select(mode)
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(title(for: mode))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DashboardTheme.text)
                            Spacer(minLength: 6)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(
                                    isSelected ? DashboardTheme.violet : DashboardTheme.mutedText
                                )
                        }

                        MenuBarModePreview(mode: mode)

                        Text(description(for: mode))
                            .font(.system(size: 10.5))
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isSelected ? DashboardTheme.surface3 : DashboardTheme.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                isSelected ? DashboardTheme.violet : DashboardTheme.border,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(for: mode))
                .accessibilityValue(
                    isSelected
                        ? L10n.text("settings.menubar_mode_selected")
                        : L10n.text("settings.menubar_mode_not_selected")
                )
                .accessibilityHint(description(for: mode))
            }
        }
    }

    private func title(for mode: MenuBarDisplayMode) -> String {
        switch mode {
        case .full: return L10n.text("settings.menubar_mode_full")
        case .compact: return L10n.text("settings.menubar_mode_compact")
        case .minimal: return L10n.text("settings.menubar_mode_minimal")
        }
    }

    private func description(for mode: MenuBarDisplayMode) -> String {
        switch mode {
        case .full: return L10n.text("settings.menubar_mode_full_description")
        case .compact: return L10n.text("settings.menubar_mode_compact_description")
        case .minimal: return L10n.text("settings.menubar_mode_minimal_description")
        }
    }
}

private struct MenuBarModePreview: View {
    let mode: MenuBarDisplayMode

    private var segments: [(ProviderQuota.Provider, String?)] {
        switch mode {
        case .full:
            return [(.claude, "99%"), (.codex, "52%")]
        case .compact:
            return [(.claude, nil), (.codex, nil)]
        case .minimal:
            return [(.codex, "52%")]
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text(mode == .compact ? "" : "·")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.82))
                }
                BrandIcon(provider: segment.0, color: .white)
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                if let value = segment.1 {
                    Text(value)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .accessibilityHidden(true)
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
    @State private var selectedCategory: SettingsCategory = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitleHeader(
                title: DashboardSection.settings.title,
                subtitle: DashboardSection.settings.subtitle
            )

            SettingsCategoryBar(selection: $selectedCategory)

            VStack(alignment: .leading, spacing: 10) {
                Text(selectedCategory.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.secondaryText)

                ScrollView(.vertical) {
                    selectedSettingsContent
                        .padding(.trailing, 5)
                        .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedCategory {
        case .general:
            generalSettings
        case .menuBar:
            menuBarSettings
        case .refreshAndSync:
            refreshAndSyncSettings
        case .about:
            aboutSettings
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: L10n.text("settings.general"))

                    preferenceToggle(
                        title: L10n.text("action.launch_at_login"),
                        detail: L10n.text("settings.login_item_note"),
                        isOn: launchAtLoginBinding
                    )

                    if let error = launchAtLogin.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(DashboardTheme.border)

                    preferenceToggle(
                        title: L10n.text("settings.show_dock_icon"),
                        detail: L10n.text("settings.show_dock_icon_hint"),
                        isOn: dockIconVisibleBinding
                    )

                    Divider().overlay(DashboardTheme.border)

                    preferenceToggle(
                        title: L10n.text("settings.floating_widget"),
                        detail: L10n.text("settings.floating_widget_hint"),
                        isOn: floatingBinding
                    )
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: L10n.text("settings.quota_details"))
                    preferenceToggle(
                        title: L10n.text("settings.antigravity_3p"),
                        detail: L10n.text("settings.antigravity_3p_hint"),
                        isOn: antigravityThirdPartyBinding
                    )
                    .disabled(!tracked.isEnabled(.antigravity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuBarSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard {
                VStack(alignment: .leading, spacing: 8) {
                    PanelHeader(
                        title: L10n.text("settings.menubar_title"),
                        subtitle: L10n.text("settings.menubar_hint")
                    )
                    FlowToggleRow(
                        providers: tracked.enabledOrdered,
                        isOn: { preferences.isInMenuBar($0) },
                        toggle: { preferences.toggleMenuBar($0) }
                    )
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 9) {
                    PanelHeader(
                        title: L10n.text("settings.menubar_mode_title"),
                        subtitle: L10n.text("settings.menubar_mode_hint")
                    )
                    MenuBarDisplayModePicker(
                        selectedMode: preferences.menuBarDisplayMode,
                        select: { preferences.setMenuBarDisplayMode($0) }
                    )
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: L10n.text("settings.model_quotas"))

                    preferenceToggle(
                        title: L10n.text("settings.menubar_codex_spark"),
                        detail: L10n.text("settings.menubar_codex_spark_hint"),
                        isOn: menuBarCodexSparkBinding
                    )
                    .disabled(!tracked.isEnabled(.codex))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var refreshAndSyncSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: L10n.text("settings.refresh_rate"))

                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(L10n.text("settings.refresh_rate_hint"))
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Picker("", selection: refreshBinding) {
                            ForEach(PreferencesStore.refreshChoices, id: \.self) { minutes in
                                Text(
                                    minutes == 0
                                        ? L10n.text("settings.manual_only")
                                        : L10n.format("settings.minutes_format", minutes)
                                )
                                .tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }

                    Divider().overlay(DashboardTheme.border)

                    HStack {
                        Spacer()
                        Button {
                            Task { await store.refresh(forceCCUsage: true, forceClaude: true) }
                        } label: {
                            Label(
                                store.isRefreshing
                                    ? L10n.text("settings.refreshing")
                                    : L10n.text("settings.refresh_now"),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(store.isRefreshing)
                        .usageDockActionButtonStyle()
                    }
                }
            }

#if TOKENREMAIN_CLOUD_SYNC
            CrossDeviceSyncSettingsCard()
#endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeader(title: L10n.text("settings.about"))
                    InfoRow(label: L10n.text("settings.version"), value: appVersion)
                    InfoRow(label: L10n.text("settings.data_label"), value: L10n.text("settings.data_value"))
                    HStack {
                        Text(L10n.text("settings.stats_source"))
                            .font(.system(size: 12))
                            .foregroundStyle(DashboardTheme.secondaryText)
                        Spacer()
                        Link("ccusage.com", destination: URL(string: "https://ccusage.com/")!)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DashboardTheme.link)
                    }
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeader(title: L10n.text("settings.actions"))
                    HStack(spacing: 10) {
                        Button {
                            launchAtLogin.restart()
                        } label: {
                            Label(L10n.text("action.restart_app"), systemImage: "arrow.clockwise.circle")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            Label(L10n.text("action.quit"), systemImage: "power")
                        }
                    }
                    .usageDockActionButtonStyle()
                    .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preferenceLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DashboardTheme.text)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func preferenceToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            preferenceLabel(title: title, detail: detail)
                .accessibilityHidden(true)
            Spacer(minLength: 16)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DashboardTheme.violet)
                .accessibilityHint(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var dockIconVisibleBinding: Binding<Bool> {
        Binding(
            get: { !preferences.dockIconHidden },
            set: { preferences.setDockIconHidden(!$0) }
        )
    }

    private var menuBarCodexSparkBinding: Binding<Bool> {
        Binding(
            get: { preferences.showCodexSparkQuotaInMenuBarWidget },
            set: { preferences.setShowCodexSparkQuotaInMenuBarWidget($0) }
        )
    }

    private var antigravityThirdPartyBinding: Binding<Bool> {
        Binding(
            get: { preferences.showAntigravityThirdPartyQuota },
            set: { preferences.setShowAntigravityThirdPartyQuota($0) }
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
