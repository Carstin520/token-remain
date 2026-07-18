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

    enum Provider: String, Sendable, Codable {
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
