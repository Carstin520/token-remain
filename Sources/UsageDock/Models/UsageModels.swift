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
        case deepseek = "DeepSeek"
        case kimi = "Kimi"
        case minimax = "MiniMax"
        case mimo = "MiMo Code"
        case qoder = "Qoder"
        case kiro = "Kiro"
        case volcengine = "Volcengine"
        case ollama = "Ollama"

        /// UI 展示与遍历用的稳定顺序(nonisolated,供任何上下文使用)。
        static let displayOrder: [Provider] = [
            .claude, .codex, .cursor, .copilot, .devin,
            .grok, .openrouter, .antigravity, .opencode, .zai,
            .deepseek, .kimi, .minimax, .mimo, .qoder,
            .kiro, .volcengine, .ollama
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
            case .deepseek: return "DeepSeek"
            case .kimi: return "Kimi"
            case .minimax: return "MiniMax"
            case .mimo: return "MiMo"
            case .qoder: return "Qoder"
            case .kiro: return "Kiro"
            case .volcengine: return "Volcengine"
            case .ollama: return "Ollama"
            }
        }
    }
}

struct DailyUsage: Sendable {
    struct Agent: Sendable, Identifiable {
        let id: String
        let tokens: Int64
        let estimatedCost: Double
        /// Model identifiers that produced tokens but had no usable price in
        /// ccusage. A zero from those rows is unknown, not a free API call.
        let unpricedModels: [String]

        init(
            id: String,
            tokens: Int64,
            estimatedCost: Double,
            unpricedModels: [String] = []
        ) {
            self.id = id
            self.tokens = tokens
            self.estimatedCost = estimatedCost
            self.unpricedModels = unpricedModels
        }
    }

    let date: String
    let agents: [Agent]
    let capturedAt: Date
}

/// Multi-day per-agent usage history, sourced from ccusage's `daily --by-agent`
/// report. Unlike `DailyUsage` (today's snapshot only) this carries one entry
/// per calendar day so the Trends section can plot a real stacked trend.
///
/// The agent collection is intentionally dynamic. ccusage can discover new
/// coding clients without requiring TokenRemain to add another fixed database
/// column or ship a new chart implementation.
struct DailyUsageHistory: Sendable, Codable {
    struct Agent: Sendable, Codable, Identifiable, Equatable {
        let id: String
        let tokens: Int64
        let cost: Double
        let unpricedModels: [String]

        init(id: String, tokens: Int64, cost: Double, unpricedModels: [String] = []) {
            self.id = id
            self.tokens = tokens
            self.cost = cost
            self.unpricedModels = unpricedModels
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case tokens
            case cost
            case unpricedModels
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            tokens = try container.decode(Int64.self, forKey: .tokens)
            cost = try container.decode(Double.self, forKey: .cost)
            unpricedModels = try container.decodeIfPresent(
                [String].self,
                forKey: .unpricedModels
            ) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(tokens, forKey: .tokens)
            try container.encode(cost, forKey: .cost)
            if !unpricedModels.isEmpty {
                try container.encode(unpricedModels, forKey: .unpricedModels)
            }
        }
    }

    struct Day: Sendable, Codable, Identifiable {
        /// Local midnight of the usage day (parsed from ccusage's `yyyy-MM-dd`).
        let date: Date
        let agents: [Agent]

        var id: Date { date }
        var totalTokens: Int64 { agents.reduce(0) { $0 + $1.tokens } }
        var totalCost: Double? {
            guard hasCompletePricing else { return nil }
            return agents.reduce(0) { $0 + $1.cost }
        }
        var knownTotalCost: Double { agents.reduce(0) { $0 + $1.cost } }
        var hasCompletePricing: Bool { agents.allSatisfy { $0.unpricedModels.isEmpty } }
        var unpricedModels: [String] {
            Array(Set(agents.flatMap(\.unpricedModels))).sorted()
        }

        /// Compatibility accessors keep the encrypted mobile-history allowlist
        /// limited to the two providers supported by the current phone schema.
        var claudeTokens: Int64 { tokens(forAgentID: "claude") }
        var claudeCost: Double { cost(forAgentID: "claude") }
        var codexTokens: Int64 { tokens(forAgentID: "codex") }
        var codexCost: Double { cost(forAgentID: "codex") }

        func tokens(for provider: ProviderQuota.Provider) -> Int64 {
            tokens(forAgentID: provider.ccusageAgentID)
        }

        func cost(for provider: ProviderQuota.Provider) -> Double {
            cost(forAgentID: provider.ccusageAgentID)
        }

        func tokens(forAgentID id: String) -> Int64 {
            agents.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.tokens ?? 0
        }

        func cost(forAgentID id: String) -> Double {
            agents.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.cost ?? 0
        }

        init(date: Date, agents: [Agent]) {
            self.date = date
            self.agents = agents
        }

        /// Source-compatible initializer for the existing sync/tests and for
        /// decoding the pre-1.1.5 cache shape.
        init(
            date: Date,
            claudeTokens: Int64,
            claudeCost: Double,
            codexTokens: Int64,
            codexCost: Double
        ) {
            self.date = date
            agents = [
                Agent(id: "claude", tokens: claudeTokens, cost: claudeCost),
                Agent(id: "codex", tokens: codexTokens, cost: codexCost)
            ].filter { $0.tokens != 0 || $0.cost != 0 }
        }

        private enum CodingKeys: String, CodingKey {
            case date
            case agents
            case claudeTokens
            case claudeCost
            case codexTokens
            case codexCost
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(Date.self, forKey: .date)
            if let decoded = try container.decodeIfPresent([Agent].self, forKey: .agents) {
                agents = decoded
            } else {
                agents = [
                    Agent(
                        id: "claude",
                        tokens: try container.decodeIfPresent(Int64.self, forKey: .claudeTokens) ?? 0,
                        cost: try container.decodeIfPresent(Double.self, forKey: .claudeCost) ?? 0
                    ),
                    Agent(
                        id: "codex",
                        tokens: try container.decodeIfPresent(Int64.self, forKey: .codexTokens) ?? 0,
                        cost: try container.decodeIfPresent(Double.self, forKey: .codexCost) ?? 0
                    )
                ].filter { $0.tokens != 0 || $0.cost != 0 }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date, forKey: .date)
            try container.encode(agents, forKey: .agents)
        }
    }

    /// Days in ascending date order (oldest first, most recent last).
    let days: [Day]
    let capturedAt: Date
}

extension ProviderQuota.Provider {
    /// ccusage's stable lower-case agent identifier. Keeping this mapping next
    /// to the provider type lets trend selection reuse the user's tracked-app
    /// choices without coupling the history model to display names.
    var ccusageAgentID: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        case .grok: "grok"
        case .zai: "zai"
        case .copilot: "copilot"
        case .devin: "devin"
        case .openrouter: "openrouter"
        case .antigravity: "antigravity"
        case .opencode: "opencode"
        case .deepseek: "deepseek"
        case .kimi: "kimi"
        case .minimax: "minimax"
        case .mimo: "mimo"
        case .qoder: "qoder"
        case .kiro: "kiro"
        case .volcengine: "volcengine"
        case .ollama: "ollama"
        }
    }
}
