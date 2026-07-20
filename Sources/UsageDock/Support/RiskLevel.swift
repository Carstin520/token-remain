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
    init(minRemainingPercent: Double?, projectedRunOut: Bool = false) {
        guard let remaining = minRemainingPercent else {
            self = .unknown
            return
        }
        switch remaining {
        case ..<10: self = .high
        case ..<30: self = .medium
        case _ where projectedRunOut: self = .medium
        default: self = .low
        }
    }

    /// Short uppercase badge, e.g. `LOW`.
    var badge: String {
        switch self {
        case .low: return L10n.text("risk.badge.low")
        case .medium: return L10n.text("risk.badge.medium")
        case .high: return L10n.text("risk.badge.high")
        case .unknown: return "—"
        }
    }

    /// One-line headline shown next to the badge.
    var headline: String {
        switch self {
        case .low: return L10n.text("risk.headline.low")
        case .medium: return L10n.text("risk.headline.medium")
        case .high: return L10n.text("risk.headline.high")
        case .unknown: return L10n.text("risk.headline.unknown")
        }
    }

    /// Fuller sentence for surfaces with more room.
    var summary: String {
        switch self {
        case .low: return L10n.text("risk.summary.low")
        case .medium: return L10n.text("risk.summary.medium")
        case .high: return L10n.text("risk.summary.high")
        case .unknown: return L10n.text("risk.summary.unknown")
        }
    }

    /// Tint mapping lives in `DashboardTheme.riskAccent` so the palette owns the
    /// three-color status language; `RiskLevel` keeps only its threshold logic.
    var tint: Color {
        DashboardTheme.riskAccent(for: self)
    }
}
