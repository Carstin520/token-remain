import SwiftUI

/// The selectable destinations in the Dashboard sidebar, grouped like the
/// prototype's MONITOR / SYSTEM sections.
enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case limits
    case trends
    case aiFeed
    case devices
    case accounts
    case dataSources
    case settings

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case monitor = "MONITOR"
        case system = "SYSTEM"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .monitor: return L10n.text("nav.group.monitor")
            case .system: return L10n.text("nav.group.system")
            }
        }
    }

    var group: Group {
        switch self {
        case .overview, .limits, .trends, .aiFeed, .devices: return .monitor
        case .accounts, .dataSources, .settings: return .system
        }
    }

    /// Sidebar / navigation title.
    var title: String {
        switch self {
        case .overview: return L10n.text("nav.overview")
        case .limits: return L10n.text("nav.limits")
        case .trends: return L10n.text("nav.trends")
        case .aiFeed: return L10n.text("widget.ai_feed")
        case .devices: return L10n.text("nav.devices")
        case .accounts: return L10n.text("nav.accounts")
        case .dataSources: return L10n.text("nav.data_sources")
        case .settings: return L10n.text("nav.settings")
        }
    }

    /// Detail-view subtitle describing the section's purpose.
    var subtitle: String {
        switch self {
        case .overview: return L10n.text("section.overview.subtitle")
        case .limits: return L10n.text("section.limits.subtitle")
        case .trends: return L10n.text("section.trends.subtitle")
        case .aiFeed: return L10n.text("feed.section_subtitle")
        case .devices: return L10n.text("section.devices.subtitle")
        case .accounts: return L10n.text("section.accounts.subtitle")
        case .dataSources: return L10n.text("section.data_sources.subtitle")
        case .settings: return L10n.text("section.settings.subtitle")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .limits: return "gauge.with.dots.needle.50percent"
        case .trends: return "chart.line.uptrend.xyaxis"
        // Same mark as the menu-bar AI Feed card.
        case .aiFeed: return "newspaper"
        case .devices: return "laptopcomputer.and.iphone"
        case .accounts: return "person.2.badge.gearshape"
        case .dataSources: return "cylinder.split.1x2"
        case .settings: return "gearshape"
        }
    }

    static func sections(in group: Group) -> [DashboardSection] {
        allCases.filter { $0.group == group }
    }
}
