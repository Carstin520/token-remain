import Foundation

/// The company behind a model identifier. Used where one quota pool serves
/// several vendors' models (Cursor "Other Models", Antigravity "Claude / GPT"),
/// so the pool row can show whose models drained it instead of a generic name.
enum ModelVendor: String, CaseIterable, Sendable {
    case anthropic
    case openai
    case google
    case xai
    case deepseek
    case moonshot
    case zhipu
    case minimax
    case alibaba
    case xiaomi
    case bytedance
    case other

    /// Hover and VoiceOver name. Brand names are not localized.
    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .google: "Google"
        case .xai: "xAI"
        case .deepseek: "DeepSeek"
        case .moonshot: "Moonshot AI"
        case .zhipu: "Z.ai"
        case .minimax: "MiniMax"
        case .alibaba: "Alibaba"
        case .xiaomi: "Xiaomi"
        case .bytedance: "ByteDance"
        case .other: L10n.text("model_vendor.other")
        }
    }

    /// Resolves the vendor from a model identifier as providers report it
    /// (`claude-4.5-sonnet-thinking`, `gpt-5-codex`, `gemini-2.5-pro`, `o3`).
    /// Matching is per name segment so a family prefix cannot hit the middle
    /// of an unrelated word; vendor names embedded anywhere (`deepseek-…-qwen`
    /// distills) are checked first because they name the actual model owner.
    static func resolve(model: String) -> ModelVendor {
        let name = model.lowercased()
        let segments = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func segment(_ prefixes: String...) -> Bool {
            segments.contains { segment in prefixes.contains { segment.hasPrefix($0) } }
        }

        if name.contains("deepseek") { return .deepseek }
        if name.contains("anthropic") || segment("claude", "opus", "sonnet", "haiku") { return .anthropic }
        if name.contains("openai") || segment("gpt", "chatgpt", "codex")
            || segments.contains(where: isOpenAIReasoningSegment) {
            return .openai
        }
        if name.contains("google") || segment("gemini", "gemma") { return .google }
        if segment("grok", "xai") { return .xai }
        if name.contains("moonshot") || segment("kimi") { return .moonshot }
        if name.contains("zhipu") || segment("glm", "chatglm") { return .zhipu }
        if name.contains("minimax") || segment("abab") { return .minimax }
        if segment("mimo") { return .xiaomi }
        if segment("doubao") { return .bytedance }
        if segment("qwen", "qwq") { return .alibaba }
        return .other
    }

    /// `o1`, `o3`, `o4`, `o3mini` and similar; a bare digit run after `o`.
    private static func isOpenAIReasoningSegment(_ segment: String) -> Bool {
        guard segment.count >= 2, segment.first == "o" else { return false }
        let rest = segment.dropFirst()
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let suffix = rest.dropFirst(digits.count)
        return suffix.isEmpty || suffix == "mini" || suffix == "pro"
    }
}

/// One vendor's share of a multi-vendor pool: the logo on the pool row and
/// the models its tooltip lists.
struct ModelVendorMark: Sendable, Equatable, Identifiable {
    struct Model: Sendable, Equatable {
        let name: String
        /// Nil when the provider reports which model families a pool covers
        /// but not how much each one used.
        var totalTokens: Int64? = nil
        var costCents: Double? = nil
    }

    let vendor: ModelVendor
    /// Largest usage first.
    let models: [Model]

    var id: String { vendor.rawValue }

    /// A pool row shows at most this many vendor logos.
    static let limit = 3
    /// Models listed per vendor in the tooltip before collapsing into a count.
    static let tooltipModelLimit = 5

    var totalTokens: Int64 {
        models.reduce(0) { $0 + ($1.totalTokens ?? 0) }
    }

    var costCents: Double {
        models.reduce(0) { $0 + ($1.costCents ?? 0) }
    }

    /// Vendor heading, then one line per model with its usage when known.
    var helpText: String {
        var lines = [vendor.displayName]
        for model in models.prefix(Self.tooltipModelLimit) {
            var parts = [model.name]
            if let tokens = model.totalTokens, tokens > 0 {
                parts.append(UsageFormatting.compactNumber(tokens))
            }
            if let cents = model.costCents, cents > 0 {
                parts.append(UsageFormatting.compactUSD(cents / 100))
            }
            lines.append(parts.joined(separator: " · "))
        }
        if models.count > Self.tooltipModelLimit {
            lines.append(L10n.format("quota.models_more", models.count - Self.tooltipModelLimit))
        }
        return lines.joined(separator: "\n")
    }

    /// Groups per-model usage by vendor and keeps the three largest vendors,
    /// ranked by token total with cost breaking ties — the same order as the
    /// card's "models this cycle" list.
    static func ranked(_ usage: [ProviderModelUsage]) -> [ModelVendorMark] {
        var order: [ModelVendor] = []
        var grouped: [ModelVendor: [Model]] = [:]
        for row in usage where row.totalTokens > 0 || (row.costCents ?? 0) > 0 {
            let vendor = ModelVendor.resolve(model: row.model)
            if grouped[vendor] == nil { order.append(vendor) }
            grouped[vendor, default: []].append(
                Model(name: row.model, totalTokens: row.totalTokens, costCents: row.costCents)
            )
        }
        let marks = order.map { vendor in
            ModelVendorMark(
                vendor: vendor,
                models: grouped[vendor, default: []].sorted {
                    ($0.totalTokens ?? 0) != ($1.totalTokens ?? 0)
                        ? ($0.totalTokens ?? 0) > ($1.totalTokens ?? 0)
                        : ($0.costCents ?? 0) > ($1.costCents ?? 0)
                }
            )
        }
        let ranked = marks.enumerated().sorted { lhs, rhs in
            if lhs.element.totalTokens != rhs.element.totalTokens {
                return lhs.element.totalTokens > rhs.element.totalTokens
            }
            if lhs.element.costCents != rhs.element.costCents {
                return lhs.element.costCents > rhs.element.costCents
            }
            return lhs.offset < rhs.offset
        }
        return ranked.prefix(limit).map(\.element)
    }
}

/// What a quota row shows for the models behind it: an optional replacement
/// for the row's name, followed by the vendor logos.
struct ModelVendorSummary: Sendable, Equatable {
    /// Replaces the pool name before the logos; nil keeps the row's own name.
    let label: String?
    let marks: [ModelVendorMark]
}

extension ProviderQuota {
    /// Label for a pool billed by models outside the tool's own family
    /// (Cursor "Other Models", Antigravity "Claude / GPT"). Kept in English
    /// like the pool names it replaces.
    static let otherModelsLabel = "Others"

    /// Relays bill every model from one balance, so their logos sit on the
    /// account's primary row.
    static let modelRelayProviders: Set<Provider> = [.openrouter, .thirdParty]

    /// Model vendors for one row of this quota, or nil when the row covers a
    /// single model family or no per-model usage is known.
    /// - Parameter scopedName: the scoped window's display name; nil for the
    ///   primary/secondary account windows.
    func modelVendorSummary(for window: QuotaWindow, scopedName: String? = nil) -> ModelVendorSummary? {
        let billingProvider = attribution?.provider ?? provider
        let poolName = scopedName ?? window.poolName
        switch billingProvider {
        case .cursor where poolName == CursorAPIUsageParser.apiPoolName:
            let thirdParty = (modelUsage ?? []).filter { !CursorAPIUsageParser.isCursorModel($0.model) }
            return Self.summary(label: Self.otherModelsLabel, marks: ModelVendorMark.ranked(thirdParty))
        case .antigravity where poolName == AntigravityUsageParser.thirdPartyPoolName:
            return Self.summary(label: Self.otherModelsLabel, marks: AntigravityUsageParser.thirdPartyVendorMarks)
        case _ where Self.modelRelayProviders.contains(billingProvider):
            guard scopedName == nil, isPrimary(window) else { return nil }
            return Self.summary(label: nil, marks: ModelVendorMark.ranked(modelUsage ?? []))
        default:
            return nil
        }
    }

    private static func summary(label: String?, marks: [ModelVendorMark]) -> ModelVendorSummary? {
        marks.isEmpty ? nil : ModelVendorSummary(label: label, marks: marks)
    }

    /// Popover rows receive bare windows; the primary is matched by value.
    private func isPrimary(_ window: QuotaWindow) -> Bool {
        window.windowMinutes == primary.windowMinutes
            && window.usedPercent == primary.usedPercent
            && window.resetsAt == primary.resetsAt
            && window.poolName == primary.poolName
    }
}
