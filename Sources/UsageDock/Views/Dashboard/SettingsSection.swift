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
                    PanelHeader(title: L10n.text("settings.general"))
                    Toggle(isOn: launchAtLoginBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("action.launch_at_login"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DashboardTheme.text)
                            Text(L10n.text("settings.login_item_note"))
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
                    PanelHeader(title: L10n.text("settings.display_refresh"))

                    // 菜单栏内容自选:任意追踪中的 provider 都可上菜单栏。
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("settings.menubar_title"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DashboardTheme.text)
                        Text(L10n.text("settings.menubar_hint"))
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
                            Text(L10n.text("settings.refresh_rate"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DashboardTheme.text)
                            Text(L10n.text("settings.refresh_rate_hint"))
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardTheme.secondaryText)
                        }
                        Spacer()
                        Picker("", selection: refreshBinding) {
                            ForEach(PreferencesStore.refreshChoices, id: \.self) { minutes in
                                Text(minutes == 0 ? L10n.text("settings.manual_only") : L10n.format("settings.minutes_format", minutes)).tag(minutes)
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
                            Text(L10n.text("settings.floating_widget"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DashboardTheme.text)
                            Text(L10n.text("settings.floating_widget_hint"))
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
                    PanelHeader(title: L10n.text("settings.actions"))
                    HStack(spacing: 10) {
                        Button {
                            Task { await store.refresh(forceCCUsage: true, forceClaude: true) }
                        } label: {
                            Label(store.isRefreshing ? L10n.text("settings.refreshing") : L10n.text("settings.refresh_now"), systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)

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
