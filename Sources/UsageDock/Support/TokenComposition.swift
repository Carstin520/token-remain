import Foundation

/// How a token total splits into input, output, cache write and cache read.
///
/// Built only from ccusage's per-model rows, so every share is measured rather
/// than inferred. Rows cached before the write/read split existed land in
/// `cacheUnsplit` instead of being guessed into either half.
struct TokenComposition: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case input
        case output
        case cacheWrite
        case cacheRead
        case cacheUnsplit

        var id: String { rawValue }

        var label: String {
            switch self {
            case .input: L10n.text("composition.input")
            case .output: L10n.text("composition.output")
            case .cacheWrite: L10n.text("composition.cache_write")
            case .cacheRead: L10n.text("composition.cache_read")
            case .cacheUnsplit: L10n.text("composition.cache_unsplit")
            }
        }
    }

    struct Part: Identifiable, Equatable, Sendable {
        let kind: Kind
        let tokens: Int64
        let share: Double

        var id: Kind { kind }
    }

    private(set) var input: Int64 = 0
    private(set) var output: Int64 = 0
    private(set) var cacheWrite: Int64 = 0
    private(set) var cacheRead: Int64 = 0
    private(set) var cacheUnsplit: Int64 = 0

    init() {}

    init(model: DailyUsageHistory.ModelUsage) {
        add(model)
    }

    init(days: [DailyUsageHistory.Day], agentIDs: Set<String>) {
        for day in days {
            for agent in day.agents where agentIDs.contains(agent.id.lowercased()) {
                for model in agent.models { add(model) }
            }
        }
    }

    mutating func add(_ model: DailyUsageHistory.ModelUsage) {
        input += max(0, model.inputTokens)
        output += max(0, model.outputTokens)
        if let write = model.cacheWriteTokens, let read = model.cacheReadTokens {
            cacheWrite += max(0, write)
            cacheRead += max(0, read)
        } else {
            cacheUnsplit += max(0, model.cacheTokens)
        }
    }

    var total: Int64 { input + output + cacheWrite + cacheRead + cacheUnsplit }

    func tokens(_ kind: Kind) -> Int64 {
        switch kind {
        case .input: input
        case .output: output
        case .cacheWrite: cacheWrite
        case .cacheRead: cacheRead
        case .cacheUnsplit: cacheUnsplit
        }
    }

    /// Parts in a fixed order. The unsplit bucket appears only when it holds
    /// tokens; the four measured kinds always appear so the legend is stable.
    var parts: [Part] {
        let total = Double(total)
        return Kind.allCases.compactMap { kind in
            let tokens = tokens(kind)
            if kind == .cacheUnsplit, tokens == 0 { return nil }
            return Part(kind: kind, tokens: tokens, share: total > 0 ? Double(tokens) / total : 0)
        }
    }
}
