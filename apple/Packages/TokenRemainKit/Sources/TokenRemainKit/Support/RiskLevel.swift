import Foundation

/// Quota-risk severity derived from the lowest remaining window across providers.
/// Ported from `Support/RiskLevel.swift` minus `tint` — colour mapping lives in
/// `TRTheme.riskAccent` so this stays a pure, testable type.
public enum RiskLevel: String, Sendable, CaseIterable {
    case low
    case medium
    case high
    /// No official quota has been read yet.
    case unknown

    /// Thresholds are expressed on remaining percentage (0…100).
    public init(minRemainingPercent: Double?, projectedRunOut: Bool = false) {
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

    /// Short uppercase badge, e.g. `LOW`. Deliberately not localized — the
    /// design renders these as pixel caps in every language.
    public var badge: String {
        switch self {
        case .low: return "LOW"
        case .medium: return "MED"
        case .high: return "HIGH"
        case .unknown: return "—"
        }
    }

    /// Non-colour differentiator, so risk never depends on hue alone.
    public var glyph: String {
        switch self {
        case .low: return ""
        case .medium: return "!"
        case .high: return "‼"
        case .unknown: return "?"
        }
    }

    public var headline: String {
        switch self {
        case .low: return TRL10n.t("risk.headline.low")
        case .medium: return TRL10n.t("risk.headline.medium")
        case .high: return TRL10n.t("risk.headline.high")
        case .unknown: return TRL10n.t("risk.headline.unknown")
        }
    }

    public var summary: String {
        switch self {
        case .low: return TRL10n.t("risk.summary.low")
        case .medium: return TRL10n.t("risk.summary.medium")
        case .high: return TRL10n.t("risk.summary.high")
        case .unknown: return TRL10n.t("risk.summary.unknown")
        }
    }
}
