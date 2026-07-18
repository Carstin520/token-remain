import SwiftUI

/// Quota-risk severity derived from the lowest remaining window across providers.
/// Risk is the product's primary signal, so it maps to an explicit label, color
/// and plain-language summary that the popover and Dashboard share.
enum RiskLevel {
    case low
    case medium
    case high
    /// No official quota has been read yet.
    case unknown

    /// Thresholds are expressed on remaining percentage (0…100).
    init(minRemainingPercent: Double?) {
        guard let remaining = minRemainingPercent else {
            self = .unknown
            return
        }
        switch remaining {
        case ..<10: self = .high
        case ..<30: self = .medium
        default: self = .low
        }
    }

    /// Short uppercase badge, e.g. `LOW`.
    var badge: String {
        switch self {
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high: return "HIGH"
        case .unknown: return "—"
        }
    }

    /// One-line headline shown next to the badge.
    var headline: String {
        switch self {
        case .low: return "使用节奏健康"
        case .medium: return "注意用量节奏"
        case .high: return "额度即将耗尽"
        case .unknown: return "等待官方额度"
        }
    }

    /// Fuller sentence for surfaces with more room.
    var summary: String {
        switch self {
        case .low: return "按当前节奏，额度充足，可以安心使用到下次重置。"
        case .medium: return "部分窗口额度偏低，建议放缓用量或关注重置时间。"
        case .high: return "额度即将耗尽，请谨慎使用，必要时等待窗口重置。"
        case .unknown: return "尚未读取到官方额度快照，稍后将自动重试。"
        }
    }

    var tint: Color {
        switch self {
        case .low: return DashboardTheme.success
        case .medium: return DashboardTheme.warning
        case .high: return DashboardTheme.danger
        case .unknown: return DashboardTheme.secondaryText
        }
    }
}
