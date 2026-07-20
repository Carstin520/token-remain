import Foundation

struct QuotaWindow: Sendable, Codable {
    let usedPercent: Double
    let windowMinutes: Int
    /// Claude can report a freshly-reset window before it knows the next reset time.
    /// Keep that official "unknown" state instead of carrying forward an expired date.
    let resetsAt: Date?
}

struct ProviderQuota: Sendable, Codable {
    let provider: Provider
    let primary: QuotaWindow
    let secondary: QuotaWindow?
    let planName: String?
    let capturedAt: Date

    enum Provider: String, Sendable, Codable, Hashable {
        case claude = "Claude Code"
        case codex = "Codex"
    }
}

struct DailyUsage: Sendable {
    struct Agent: Sendable, Identifiable {
        let id: String
        let tokens: Int64
        let estimatedCost: Double
    }

    let date: String
    let agents: [Agent]
    let capturedAt: Date
}

/// Multi-day per-agent usage history, sourced from ccusage's `daily --by-agent`
/// report. Unlike `DailyUsage` (today's snapshot only) this carries one entry
/// per calendar day so the Trends section can plot a real stacked trend. Claude
/// and Codex are kept as fixed columns so the stack order never shuffles.
struct DailyUsageHistory: Sendable, Codable {
    struct Day: Sendable, Codable, Identifiable {
        /// Local midnight of the usage day (parsed from ccusage's `yyyy-MM-dd`).
        let date: Date
        let claudeTokens: Int64
        let claudeCost: Double
        let codexTokens: Int64
        let codexCost: Double

        var id: Date { date }
        var totalTokens: Int64 { claudeTokens + codexTokens }
        var totalCost: Double { claudeCost + codexCost }

        func tokens(for provider: ProviderQuota.Provider) -> Int64 {
            provider == .claude ? claudeTokens : codexTokens
        }
        func cost(for provider: ProviderQuota.Provider) -> Double {
            provider == .claude ? claudeCost : codexCost
        }
    }

    /// Days in ascending date order (oldest first, most recent last).
    let days: [Day]
    let capturedAt: Date
}
