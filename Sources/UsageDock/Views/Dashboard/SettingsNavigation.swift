import SwiftUI

/// The second navigation level inside Dashboard Settings. Keeping these
/// categories separate from `DashboardSection` prevents individual preferences
/// from leaking into the app-wide sidebar while still making every group one
/// click away.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case refreshAndSync
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("settings.general")
        case .menuBar: L10n.text("settings.menubar_title")
        case .refreshAndSync: L10n.text("settings.refresh_sync")
        case .about: L10n.text("settings.about")
        }
    }

    var detail: String {
        switch self {
        case .general: L10n.text("settings.category_general_detail")
        case .menuBar: L10n.text("settings.category_menubar_detail")
        case .refreshAndSync: L10n.text("settings.category_refresh_detail")
        case .about: L10n.text("settings.category_about_detail")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "switch.2"
        case .menuBar: "menubar.rectangle"
        case .refreshAndSync: "arrow.triangle.2.circlepath.icloud"
        case .about: "info.circle"
        }
    }
}

struct SettingsCategoryBar: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        DashboardCard(padding: 6) {
            HStack(spacing: 4) {
                ForEach(SettingsCategory.allCases) { category in
                    SettingsCategoryTab(
                        category: category,
                        isSelected: selection == category,
                        select: { selection = category }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SettingsCategoryTab: View {
    let category: SettingsCategory
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)

                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? Color.white : DashboardTheme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? DashboardTheme.violet
                            : (isHovering ? DashboardTheme.surface3 : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(category.title)
        .accessibilityHint(category.detail)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
