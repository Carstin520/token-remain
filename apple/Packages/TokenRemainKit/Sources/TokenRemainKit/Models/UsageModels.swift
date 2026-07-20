import Foundation

/// Ported unchanged in shape from `Sources/UsageDock/Models/UsageModels.swift`.
/// Duplicated rather than imported: the macOS sources are outside this subtree
/// and must not be touched.
public struct QuotaWindow: Sendable, Codable, Equatable {
    public let usedPercent: Double
    public let windowMinutes: Int
    /// Claude can report a freshly-reset window before it knows the next reset time.
    /// Keep that official "unknown" state instead of carrying forward an expired date.
    public let resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct ProviderQuota: Sendable, Codable, Equatable {
    public let provider: Provider
    public let primary: QuotaWindow
    public let secondary: QuotaWindow?
    public let planName: String?
    public let capturedAt: Date

    public enum Provider: String, Sendable, Codable, CaseIterable {
        case claude = "Claude Code"
        case codex = "Codex"

        /// Short name used across compact surfaces.
        public var shortName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            }
        }
    }

    public init(
        provider: Provider,
        primary: QuotaWindow,
        secondary: QuotaWindow?,
        planName: String?,
        capturedAt: Date
    ) {
        self.provider = provider
        self.primary = primary
        self.secondary = secondary
        self.planName = planName
        self.capturedAt = capturedAt
    }
}

/// Demo-only per-agent token split. Never populated in `.none` origin.
public struct AgentTokens: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let tokens: Int64
    public let estimatedCost: Double

    public init(id: String, tokens: Int64, estimatedCost: Double) {
        self.id = id
        self.tokens = tokens
        self.estimatedCost = estimatedCost
    }
}
