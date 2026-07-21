import Foundation

struct QuotaWindow: Sendable, Codable {
    let usedPercent: Double
    let windowMinutes: Int
    /// Claude can report a freshly-reset window before it knows the next reset time.
    /// Keep that official "unknown" state instead of carrying forward an expired date.
    let resetsAt: Date?
}

/// 订阅限额之外的按量付费消费(Claude 的 extra usage credits)。
struct ExtraUsage: Sendable, Codable, Equatable {
    let spentUSD: Double
    /// 月度上限;未设上限时为 nil。
    let monthlyLimitUSD: Double?
}

struct ProviderQuota: Sendable, Codable {
    let provider: Provider
    let primary: QuotaWindow
    let secondary: QuotaWindow?
    let planName: String?
    let capturedAt: Date
    var extraUsage: ExtraUsage? = nil

    enum Provider: String, Sendable, Codable, Hashable {
        case claude = "Claude Code"
        case codex = "Codex"
        case cursor = "Cursor"
        case grok = "Grok"
        case zai = "Z.ai"
        case copilot = "Copilot"
        case devin = "Devin"
        case openrouter = "OpenRouter"
        case antigravity = "Antigravity"
        case opencode = "OpenCode"

        /// UI 展示与遍历用的稳定顺序(nonisolated,供任何上下文使用)。
        static let displayOrder: [Provider] = [
            .claude, .codex, .cursor, .copilot, .devin,
            .grok, .openrouter, .antigravity, .opencode, .zai
        ]

        /// UI 里的短名(rawValue 保留历史值以兼容缓存/持久化)。
        var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            case .grok: return "Grok"
            case .zai: return "Z.ai"
            case .copilot: return "Copilot"
            case .devin: return "Devin"
            case .openrouter: return "OpenRouter"
            case .antigravity: return "Antigravity"
            case .opencode: return "OpenCode"
            }
        }
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
            switch provider {
            case .claude: return claudeTokens
            case .codex: return codexTokens
            default: return 0
            }
        }
        func cost(for provider: ProviderQuota.Provider) -> Double {
            switch provider {
            case .claude: return claudeCost
            case .codex: return codexCost
            default: return 0
            }
        }
    }

    /// Days in ascending date order (oldest first, most recent last).
    let days: [Day]
    let capturedAt: Date
}
