import SwiftUI

/// The selectable destinations in the Dashboard sidebar, grouped like the
/// prototype's MONITOR / SYSTEM sections.
enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case aiFeed
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
    }

    var group: Group {
        switch self {
        case .overview, .aiFeed, .limits, .trends, .devices: return .monitor
        case .dataSources, .settings: return .system
        }
    }

    /// Sidebar / navigation title.
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .aiFeed: return "AI Feed"
        case .limits: return "Limits"
        case .trends: return "Trends"
        case .devices: return "Devices"
        case .dataSources: return "Data Sources"
        case .settings: return "Settings"
        }
    }

    /// Detail-view subtitle describing the section's purpose.
    var subtitle: String {
        switch self {
        case .overview: return "掌握额度风险、今日用量与预估成本"
        case .aiFeed: return "与你的额度和工作流直接相关的精选更新"
        case .limits: return "Claude 与 Codex 官方额度窗口明细"
        case .trends: return "跨天使用趋势（正在采集历史数据）"
        case .devices: return "本机与未来跨设备监测"
        case .dataSources: return "数据来源状态与隐私说明"
        case .settings: return "启动项、刷新与应用操作"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .aiFeed: return "dot.radiowaves.left.and.right"
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
