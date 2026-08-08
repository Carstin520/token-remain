import Foundation

struct QuotaWindow: Sendable, Codable {
    let usedPercent: Double
    let windowMinutes: Int
    /// Claude can report a freshly-reset window before it knows the next reset time.
    /// Keep that official "unknown" state instead of carrying forward an expired date.
    let resetsAt: Date?
    /// Some providers expose a monetary cap for each individual window. The
    /// percentage still drives the meter; this replaces only the remaining text.
    var remainingBalance: QuotaBalance? = nil
}

/// A monetary remainder reported or derived for one quota window. The meter
/// still uses `QuotaWindow.usedPercent`; this replaces only its remaining text.
struct QuotaBalance: Sendable, Codable, Equatable {
    let amount: Double
    let currencyCode: String

    var displayText: String {
        let normalizedCode = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let symbol = switch normalizedCode {
        case "CNY", "JPY": "¥"
        case "USD": "$"
        case "EUR": "€"
        case "GBP": "£"
        default: normalizedCode.isEmpty ? "" : "\(normalizedCode) "
        }
        let safeAmount = amount.isFinite ? max(0, amount) : 0
        return "\(symbol)\(String(format: "%.2f", safeAmount))"
    }
}

/// A provider-specific quota that shares a duration with a general window but
/// applies to a named model or product scope (for example Claude's Fable cap).
struct ScopedQuotaWindow: Sendable, Codable {
    let scopeID: String
    let displayName: String
    let window: QuotaWindow

    var isFable: Bool {
        scopeID.lowercased().hasPrefix("fable")
            || displayName.localizedCaseInsensitiveContains("Fable")
    }

    var isCodexSpark: Bool {
        scopeID.caseInsensitiveCompare("codex_bengalfox") == .orderedSame
            || displayName.localizedCaseInsensitiveContains("Codex-Spark")
    }

    var isAntigravityThirdParty: Bool {
        scopeID.lowercased().hasPrefix("antigravity_3p_")
    }

    /// Claude Code names the general weekly cap `Current week (all models)`.
    /// It is the same value as the secondary window, never a model-scoped one,
    /// so a reading carrying that label must not become an extra card.
    var isGeneralWeeklyLabel: Bool {
        Self.isGeneralWeeklyLabel(scopeID) || Self.isGeneralWeeklyLabel(displayName)
    }

    /// Terminal repainting drops glyphs from the label — `all odels`,
    /// `ll models`, and a copy captured before the trailing `s` painted all
    /// reach the parser. Accept any spelling that is still `all models` with up
    /// to two characters missing; no real model name survives that test.
    static func isGeneralWeeklyLabel(_ name: String) -> Bool {
        let reference = "allmodels"
        let normalized = name.lowercased().filter { $0.isASCII && $0.isLetter }
        guard normalized.count >= reference.count - 2 else { return false }
        var index = normalized.startIndex
        for character in reference where index < normalized.endIndex {
            if normalized[index] == character {
                index = normalized.index(after: index)
            }
        }
        return index == normalized.endIndex
    }
}

/// 订阅限额之外的按量付费消费(Claude 的 extra usage credits)。
struct ExtraUsage: Sendable, Codable, Equatable {
    let spentUSD: Double
    /// 月度上限;未设上限时为 nil。
    let monthlyLimitUSD: Double?
}

/// Provider-reported API spend buckets. These are account aggregates rather
/// than TokenRemain's local ccusage estimates, so keep them attached to the
/// official provider snapshot and never infer missing buckets as zero.
struct ProviderSpend: Sendable, Codable, Equatable {
    let todayUSD: Double?
    let weekUSD: Double?
    let monthUSD: Double?
    let allTimeUSD: Double?

    var hasValues: Bool {
        [todayUSD, weekUSD, monthUSD, allTimeUSD].contains { value in
            value?.isFinite == true
        }
    }
}

/// Saved Codex rate-limit resets reported by ChatGPT's usage service. OpenAI's
/// documented `account/rateLimits/read` contract calls `availableCount`
/// authoritative. The private wham response can also contain an undocumented
/// `applicable_available_count`; do not persist or interpret it as UI state.
struct CodexRateLimitResetCredits: Sendable, Codable, Equatable {
    let availableCount: Int
}

/// Identifies the account/API that actually owns a quota while preserving the
/// host application as `ProviderQuota.provider`. For example, Claude Code can
/// remain the card identity while its balance is attributed to DeepSeek API.
/// Only a normalized route identifier is cached; credentials and full URLs are
/// deliberately excluded from this model.
struct QuotaAttribution: Sendable, Codable, Equatable {
    let provider: ProviderQuota.Provider?
    let displayName: String
    let routeIdentifier: String
}

/// Chooses which account-wide window represents a provider on compact summary
/// surfaces. Named model/pool limits are never candidates for either strategy.
enum QuotaSummaryStrategy: String, CaseIterable, Identifiable, Sendable {
    case shortestWindow
    case lowestRemaining

    var id: String { rawValue }
}

struct ProviderQuota: Sendable, Codable {
    struct GeneralQuotaSummary: Sendable {
        let window: QuotaWindow
        let remainingPercent: Double
        let remainingBalance: QuotaBalance?
    }

    let provider: Provider
    let primary: QuotaWindow
    let secondary: QuotaWindow?
    let planName: String?
    let capturedAt: Date
    var extraUsage: ExtraUsage? = nil
    /// Optional so older cached snapshots continue to decode unchanged.
    var spend: ProviderSpend? = nil
    /// A provider-wide wallet that is distinct from any individual rate-limit
    /// window. Kept out of mobile sync until the shared schema has an explicit
    /// balance field instead of overloading duplicate zero-minute windows.
    var accountBalance: QuotaBalance? = nil
    /// Optional so existing cached snapshots decode without a schema migration.
    var scopedWindows: [ScopedQuotaWindow]? = nil
    /// Legacy primary-window field retained so existing caches stay compatible.
    /// New multi-window data belongs on each `QuotaWindow`.
    var remainingBalance: QuotaBalance? = nil
    /// Codex-only banked resets. Nil means the current source did not expose the
    /// official reset-credit fields; zero is a real, successfully fetched count.
    var codexResetCredits: CodexRateLimitResetCredits? = nil
    /// Nil means the quota belongs to the host provider itself. A non-nil value
    /// names the API account that supplied the displayed limit or balance.
    var attribution: QuotaAttribution? = nil

    /// The shortest account-wide window is the default compact/headline value.
    /// This preserves the historical 5-hour-first behavior while keeping named
    /// model or pool limits out of every account-level summary.
    var generalQuotaSummary: GeneralQuotaSummary {
        generalQuotaSummary(strategy: .shortestWindow)
    }

    func generalQuotaSummary(strategy: QuotaSummaryStrategy) -> GeneralQuotaSummary {
        let primarySummary = GeneralQuotaSummary(
            window: primary,
            remainingPercent: Self.remainingPercent(for: primary),
            remainingBalance: primary.remainingBalance ?? remainingBalance
        )
        guard let secondary else { return primarySummary }

        let secondarySummary = GeneralQuotaSummary(
            window: secondary,
            remainingPercent: Self.remainingPercent(for: secondary),
            remainingBalance: secondary.remainingBalance
        )
        switch strategy {
        case .shortestWindow:
            let primaryDuration = Self.summaryDuration(primarySummary.window.windowMinutes)
            let secondaryDuration = Self.summaryDuration(secondarySummary.window.windowMinutes)
            return secondaryDuration < primaryDuration ? secondarySummary : primarySummary
        case .lowestRemaining:
            if secondarySummary.remainingPercent == primarySummary.remainingPercent {
                return Self.summaryDuration(secondarySummary.window.windowMinutes)
                    < Self.summaryDuration(primarySummary.window.windowMinutes)
                    ? secondarySummary
                    : primarySummary
            }
            return secondarySummary.remainingPercent < primarySummary.remainingPercent
                ? secondarySummary
                : primarySummary
        }
    }

    private static func summaryDuration(_ minutes: Int) -> Int {
        minutes > 0 ? minutes : .max
    }

    private static func remainingPercent(for window: QuotaWindow) -> Double {
        guard window.usedPercent.isFinite else { return 100 }
        return min(100, max(0, 100 - window.usedPercent))
    }

    /// Terminal repainting and older cached snapshots can contain the same
    /// model-scoped quota more than once. Keep the latest reading for each
    /// stable scope while preserving the service's original display order.
    /// Damaged `all models` labels are dropped here rather than only at parse
    /// time, so a snapshot cached before the parser learned to reject them
    /// stops rendering phantom cards on the next launch.
    var uniqueScopedWindows: [ScopedQuotaWindow] {
        var order: [String] = []
        var latestByScope: [String: ScopedQuotaWindow] = [:]
        for scoped in scopedWindows ?? [] where !scoped.isGeneralWeeklyLabel {
            let key = scoped.scopeID.lowercased()
            if latestByScope[key] == nil {
                order.append(key)
            }
            latestByScope[key] = scoped
        }
        return order.compactMap { latestByScope[$0] }
    }

    /// Claude currently names this model-scoped weekly cap `fable`, but keep
    /// the lookup tolerant of a future version suffix such as `fable_5`.
    var fableWindow: ScopedQuotaWindow? {
        uniqueScopedWindows.first(where: \.isFable)
    }

    /// Keeps the authoritative primary/all-model values while filling model-
    /// scoped windows from a secondary source such as Claude Code's `/usage`
    /// screen. Current-source entries win if both sources report the same ID.
    func mergingScopedWindows(_ supplemental: [ScopedQuotaWindow]) -> ProviderQuota {
        var order: [String] = []
        var latestByScope: [String: ScopedQuotaWindow] = [:]
        for scoped in supplemental + uniqueScopedWindows {
            let key = scoped.scopeID.lowercased()
            if latestByScope[key] == nil {
                order.append(key)
            }
            latestByScope[key] = scoped
        }
        let merged = order.compactMap { latestByScope[$0] }
        return ProviderQuota(
            provider: provider,
            primary: primary,
            secondary: secondary,
            planName: planName,
            capturedAt: capturedAt,
            extraUsage: extraUsage,
            spend: spend,
            accountBalance: accountBalance,
            scopedWindows: merged.isEmpty ? nil : merged,
            remainingBalance: remainingBalance,
            codexResetCredits: codexResetCredits,
            attribution: attribution
        )
    }

    /// Re-hosts an API provider's quota under the application that consumed it.
    /// The billing source remains explicit so UI and caches never imply that a
    /// DeepSeek/OpenRouter balance is an official Claude or Codex allowance.
    func attributed(
        to hostProvider: Provider,
        source: QuotaAttribution
    ) -> ProviderQuota {
        ProviderQuota(
            provider: hostProvider,
            primary: primary,
            secondary: secondary,
            planName: planName,
            capturedAt: capturedAt,
            extraUsage: extraUsage,
            spend: spend,
            accountBalance: accountBalance,
            scopedWindows: scopedWindows,
            remainingBalance: remainingBalance,
            codexResetCredits: codexResetCredits,
            attribution: source
        )
    }

    /// A general account refresh can succeed while the secondary `/usage`
    /// probe temporarily omits model-scoped rows. Preserve the previous
    /// window only while it still belongs to the current quota cycle; a newer
    /// scoped value from this snapshot always wins in `mergingScopedWindows`.
    func retainingActiveScopedWindows(
        from previous: ProviderQuota,
        now: Date,
        undatedRetention: TimeInterval = 86_400
    ) -> ProviderQuota {
        let active = previous.uniqueScopedWindows.filter { scoped in
            if let resetsAt = scoped.window.resetsAt {
                return resetsAt > now
            }
            return now.timeIntervalSince(previous.capturedAt) < undatedRetention
        }
        return mergingScopedWindows(active)
    }

    enum Provider: String, Sendable, Codable, Hashable {
        case claude = "Claude Code"
        case codex = "Codex"
        case cursor = "Cursor"
        case grok = "Grok"
        case zai = "Z.ai"
        case zaiTeam = "GLM Team"
        case copilot = "Copilot"
        case devin = "Devin"
        case windsurf = "Windsurf"
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
        case thirdParty = "Third-party APIs"

        /// UI 展示与遍历用的稳定顺序(nonisolated,供任何上下文使用)。
        static let displayOrder: [Provider] = [
            .claude, .codex, .cursor, .copilot, .devin, .windsurf,
            .grok, .openrouter, .antigravity, .opencode, .zai, .zaiTeam,
            .deepseek, .kimi, .minimax, .mimo, .qoder,
            .kiro, .volcengine, .ollama, .thirdParty
        ]

        /// UI 里的短名(rawValue 保留历史值以兼容缓存/持久化)。
        var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            case .grok: return "Grok"
            case .zai: return "Z.ai"
            case .zaiTeam: return "GLM Team"
            case .copilot: return "Copilot"
            case .devin: return "Devin"
            case .windsurf: return "Windsurf"
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
            case .thirdParty: return "Third-party"
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
    struct ModelUsage: Sendable, Codable, Identifiable, Equatable {
        let id: String
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheTokens: Int64
        let cost: Double
        /// Number of concrete model identifiers represented by this row.
        /// Named rows remain one; the bounded `other` row carries its tail size.
        let constituentCount: Int

        init(
            id: String,
            inputTokens: Int64,
            outputTokens: Int64,
            cacheTokens: Int64,
            cost: Double,
            constituentCount: Int = 1
        ) {
            self.id = id
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheTokens = cacheTokens
            self.cost = cost
            self.constituentCount = max(1, constituentCount)
        }

        private enum CodingKeys: String, CodingKey {
            case id, inputTokens, outputTokens, cacheTokens, cost, constituentCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            inputTokens = try container.decode(Int64.self, forKey: .inputTokens)
            outputTokens = try container.decode(Int64.self, forKey: .outputTokens)
            cacheTokens = try container.decode(Int64.self, forKey: .cacheTokens)
            cost = try container.decode(Double.self, forKey: .cost)
            constituentCount = max(
                1,
                try container.decodeIfPresent(Int.self, forKey: .constituentCount) ?? 1
            )
        }

        var totalTokens: Int64 {
            inputTokens + outputTokens + cacheTokens
        }
    }

    struct Agent: Sendable, Codable, Identifiable, Equatable {
        let id: String
        let tokens: Int64
        let cost: Double
        let unpricedModels: [String]
        let models: [ModelUsage]

        init(
            id: String,
            tokens: Int64,
            cost: Double,
            unpricedModels: [String] = [],
            models: [ModelUsage] = []
        ) {
            self.id = id
            self.tokens = tokens
            self.cost = cost
            self.unpricedModels = unpricedModels
            self.models = DailyUsageHistory.boundedModels(models)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case tokens
            case cost
            case unpricedModels
            case models
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
            models = DailyUsageHistory.boundedModels(
                try container.decodeIfPresent([ModelUsage].self, forKey: .models) ?? []
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(tokens, forKey: .tokens)
            try container.encode(cost, forKey: .cost)
            if !unpricedModels.isEmpty {
                try container.encode(unpricedModels, forKey: .unpricedModels)
            }
            if !models.isEmpty {
                try container.encode(models, forKey: .models)
            }
        }
    }

    /// Keep the local cache economically bounded even when a relay reports many
    /// short-lived model aliases. Seven named rows plus one aggregated tail is
    /// enough for the on-demand Dashboard detail without growing sync payloads.
    static func boundedModels(_ rows: [ModelUsage], cap: Int = 8) -> [ModelUsage] {
        guard cap > 0 else { return [] }
        var merged: [String: ModelUsage] = [:]
        for row in rows {
            let id = row.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty, id != "<synthetic>" else { continue }
            let previous = merged[id]
            merged[id] = ModelUsage(
                id: id,
                inputTokens: (previous?.inputTokens ?? 0) + max(0, row.inputTokens),
                outputTokens: (previous?.outputTokens ?? 0) + max(0, row.outputTokens),
                cacheTokens: (previous?.cacheTokens ?? 0) + max(0, row.cacheTokens),
                cost: (previous?.cost ?? 0) + max(0, row.cost),
                constituentCount: max(previous?.constituentCount ?? 1, row.constituentCount)
            )
        }

        let carriedOther = merged.removeValue(forKey: "other")
        let ordered = merged.values.sorted {
            if $0.totalTokens == $1.totalTokens {
                if $0.cost == $1.cost { return $0.id < $1.id }
                return $0.cost > $1.cost
            }
            return $0.totalTokens > $1.totalTokens
        }
        if ordered.count + (carriedOther == nil ? 0 : 1) <= cap {
            return ordered + [carriedOther].compactMap { $0 }
        }

        let namedCount = max(0, cap - 1)
        let kept = Array(ordered.prefix(namedCount))
        let tail = Array(ordered.dropFirst(namedCount)) + [carriedOther].compactMap { $0 }
        guard let firstTail = tail.first else { return kept }
        let other = tail.dropFirst().reduce(
            ModelUsage(
                id: "other",
                inputTokens: firstTail.inputTokens,
                outputTokens: firstTail.outputTokens,
                cacheTokens: firstTail.cacheTokens,
                cost: firstTail.cost,
                constituentCount: firstTail.constituentCount
            )
        ) { result, row in
            ModelUsage(
                id: "other",
                inputTokens: result.inputTokens + row.inputTokens,
                outputTokens: result.outputTokens + row.outputTokens,
                cacheTokens: result.cacheTokens + row.cacheTokens,
                cost: result.cost + row.cost,
                constituentCount: result.constituentCount + row.constituentCount
            )
        }
        return other.totalTokens > 0 || other.cost > 0 ? kept + [other] : kept
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

/// Common output shared by the bundled ccusage collector and app-owned local
/// parsers. New coding tools merge into this string-keyed model instead of
/// expanding the fixed quota-provider enum.
struct LocalUsageSnapshot: Sendable {
    let daily: DailyUsage
    let history: DailyUsageHistory

    func merging(_ other: LocalUsageSnapshot) -> LocalUsageSnapshot {
        LocalUsageSnapshot(
            daily: DailyUsage(
                date: max(daily.date, other.daily.date),
                agents: Self.mergeDailyAgents(daily.agents + other.daily.agents),
                capturedAt: max(daily.capturedAt, other.daily.capturedAt)
            ),
            history: DailyUsageHistory(
                days: Self.mergeHistoryDays(history.days + other.history.days),
                capturedAt: max(history.capturedAt, other.history.capturedAt)
            )
        )
    }

    private static func mergeDailyAgents(_ agents: [DailyUsage.Agent]) -> [DailyUsage.Agent] {
        var merged: [String: DailyUsage.Agent] = [:]
        for agent in agents {
            let id = LocalUsageSourceCatalog.canonicalID(agent.id)
            guard LocalUsageSourceCatalog.isWellFormed(id) else { continue }
            let previous = merged[id]
            merged[id] = DailyUsage.Agent(
                id: id,
                tokens: (previous?.tokens ?? 0) + max(0, agent.tokens),
                estimatedCost: (previous?.estimatedCost ?? 0) + max(0, agent.estimatedCost),
                unpricedModels: Array(Set(
                    (previous?.unpricedModels ?? []) + agent.unpricedModels
                )).sorted()
            )
        }
        return merged.values.sorted { lhs, rhs in
            LocalUsageSourceCatalog.sortKey(lhs.id) < LocalUsageSourceCatalog.sortKey(rhs.id)
        }
    }

    private static func mergeHistoryDays(
        _ days: [DailyUsageHistory.Day]
    ) -> [DailyUsageHistory.Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var byDay: [Date: [DailyUsageHistory.Agent]] = [:]
        for day in days {
            byDay[calendar.startOfDay(for: day.date), default: []].append(contentsOf: day.agents)
        }
        return byDay.map { date, agents in
            var merged: [String: DailyUsageHistory.Agent] = [:]
            for agent in agents {
                let id = LocalUsageSourceCatalog.canonicalID(agent.id)
                guard LocalUsageSourceCatalog.isWellFormed(id) else { continue }
                let previous = merged[id]
                merged[id] = DailyUsageHistory.Agent(
                    id: id,
                    tokens: (previous?.tokens ?? 0) + max(0, agent.tokens),
                    cost: (previous?.cost ?? 0) + max(0, agent.cost),
                    unpricedModels: Array(Set(
                        (previous?.unpricedModels ?? []) + agent.unpricedModels
                    )).sorted(),
                    models: DailyUsageHistory.boundedModels(
                        (previous?.models ?? []) + agent.models
                    )
                )
            }
            return DailyUsageHistory.Day(
                date: date,
                agents: merged.values.sorted { lhs, rhs in
                    LocalUsageSourceCatalog.sortKey(lhs.id)
                        < LocalUsageSourceCatalog.sortKey(rhs.id)
                }
            )
        }
        .sorted { $0.date < $1.date }
    }
}

enum LocalUsageSourceCatalog {
    struct Definition: Sendable, Equatable {
        let id: String
        let displayName: String
    }

    /// Matches the source IDs published by the bundled ccusage helper, plus the
    /// app-owned Trae Agent trajectory parser.
    static let supported: [Definition] = [
        .init(id: "claude", displayName: "Claude Code"),
        .init(id: "codex", displayName: "Codex"),
        .init(id: "opencode", displayName: "OpenCode"),
        .init(id: "amp", displayName: "Amp"),
        .init(id: "droid", displayName: "Droid"),
        .init(id: "codebuff", displayName: "Codebuff"),
        .init(id: "hermes", displayName: "Hermes Agent"),
        .init(id: "pi", displayName: "pi-agent"),
        .init(id: "goose", displayName: "Goose"),
        .init(id: "openclaw", displayName: "OpenClaw"),
        .init(id: "kilo", displayName: "Kilo Code"),
        .init(id: "kimi", displayName: "Kimi CLI"),
        .init(id: "qwen", displayName: "Qwen CLI"),
        .init(id: "copilot", displayName: "GitHub Copilot CLI"),
        .init(id: "gemini", displayName: "Gemini"),
        .init(id: "trae-agent", displayName: "Trae Agent")
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: supported.map { ($0.id, $0) })

    static func canonicalID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isWellFormed(_ value: String) -> Bool {
        let id = canonicalID(value)
        guard (1...64).contains(id.utf8.count), let first = id.utf8.first else { return false }
        guard first.isASCIIAlphaNumeric else { return false }
        return id.utf8.allSatisfy { byte in
            byte.isASCIIAlphaNumeric || byte == 45 || byte == 46 || byte == 95
        }
    }

    static func displayName(for id: String) -> String {
        let canonical = canonicalID(id)
        return byID[canonical]?.displayName
            ?? canonical.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.capitalized }
                .joined(separator: " ")
    }

    static func sortKey(_ id: String) -> String {
        let canonical = canonicalID(id)
        let index = supported.firstIndex { $0.id == canonical } ?? supported.count
        return String(format: "%03d-%@", index, canonical)
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (48...57).contains(self) || (97...122).contains(self)
    }
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
        case .zaiTeam: "zaiteam"
        case .copilot: "copilot"
        case .devin: "devin"
        case .windsurf: "windsurf"
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
        case .thirdParty: "thirdparty"
        }
    }
}
