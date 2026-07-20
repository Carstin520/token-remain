import SwiftUI

/// The selectable destinations in the Dashboard sidebar, grouped like the
/// prototype's MONITOR / SYSTEM sections.
enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case limits
    case trends
    case devices
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
        case .overview, .limits, .trends, .devices: return .monitor
        case .dataSources, .settings: return .system
        }
    }

    /// Sidebar / navigation title.
    var title: String {
        switch self {
        case .overview: return L10n.text("nav.overview")
        case .limits: return L10n.text("nav.limits")
        case .trends: return L10n.text("nav.trends")
        case .devices: return L10n.text("nav.devices")
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
        case .devices: return L10n.text("section.devices.subtitle")
        case .dataSources: return L10n.text("section.data_sources.subtitle")
        case .settings: return L10n.text("section.settings.subtitle")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .limits: return "gauge.with.dots.needle.50percent"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .devices: return "laptopcomputer.and.iphone"
        case .dataSources: return "cylinder.split.1x2"
        case .settings: return "gearshape"
        }
    }

    static func sections(in group: Group) -> [DashboardSection] {
        allCases.filter { $0.group == group }
    }
}
