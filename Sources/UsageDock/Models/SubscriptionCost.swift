import Foundation

/// A subscription tier with a published monthly list price: USD, monthly
/// billing, before tax. It is what a vendor's pricing page lists, not what any
/// one user pays — annual billing, regional App Store pricing and seat plans
/// all differ — so every account can override it in `SubscriptionCostStore`.
struct SubscriptionPlan: Sendable, Equatable, Identifiable {
    let id: String
    let provider: ProviderQuota.Provider
    let displayName: String
    let monthlyUSD: Double
    /// Usage allowance relative to the provider's base paid tier, as the
    /// vendor states it (Claude Ultra = 20). Nil for free tiers and tiers whose
    /// multiple is not published; advice never downgrades into such a tier.
    let relativeCapacity: Double?
    /// Normalized `planName` spellings that identify this tier. Both the raw
    /// local-log value (Codex `prolite`) and the API label (`Pro 5x`) appear.
    let aliases: Set<String>
}

/// Recognizes the plans whose list price is known. Seat-priced, quote-only and
/// ambiguous tiers (a bare Claude "Max", ChatGPT Team) are deliberately
/// absent: an unrecognized plan asks the user for a price rather than
/// borrowing a neighbouring tier's. Claude's local credentials report the
/// subscription type "max" for both of its upper tiers, and since the
/// October 2026 rename "Max" is also the $100 tier's own name, so only a
/// label carrying the tier (`Max 5x`, `Max 20x`, `Ultra`) is priced. The same tiers are offered in the
/// price editor, so a source that reports no plan (Claude Web, Antigravity)
/// can still be priced by choosing one.
enum SubscriptionPlanCatalog {
    /// When the prices below were last checked against vendor pricing pages
    /// and public plan comparisons. Shown on the card so a stale table is
    /// visible instead of silently authoritative.
    static let checkedOn = "2026-10-30"

    static let plans: [SubscriptionPlan] = [
        plan(.claude, "claude.free", "Free", 0, nil, ["free"]),
        plan(.claude, "claude.pro", "Pro", 20, 1, ["pro"]),
        // Anthropic renamed these in October 2026 (Max 5x → Max, Max 20x →
        // Ultra) at the same prices. The ids are stored in price overrides
        // and quota history, so they keep the old spelling; sources may
        // report either name.
        plan(.claude, "claude.max5x", "Max", 100, 5, ["max5x"]),
        plan(.claude, "claude.max20x", "Ultra", 200, 20, ["max20x", "ultra"]),
        plan(.codex, "codex.free", "Free", 0, nil, ["free"]),
        plan(.codex, "codex.plus", "Plus", 20, 1, ["plus"]),
        plan(.codex, "codex.pro5x", "Pro 5x", 100, 5, ["prolite", "pro5x"]),
        plan(.codex, "codex.pro20x", "Pro 20x", 200, 20, ["pro", "pro20x"]),
        plan(.cursor, "cursor.hobby", "Hobby", 0, nil, ["free", "hobby"]),
        plan(.cursor, "cursor.pro", "Pro", 20, 1, ["pro"]),
        plan(.cursor, "cursor.proplus", "Pro+", 60, 3, ["proplus"]),
        plan(.cursor, "cursor.ultra", "Ultra", 200, 20, ["ultra"]),
        plan(.copilot, "copilot.free", "Free", 0, nil, ["free", "copilotfree"]),
        plan(.copilot, "copilot.pro", "Pro", 10, 1, ["pro", "copilotpro"]),
        plan(.copilot, "copilot.proplus", "Pro+", 39, 5, ["proplus", "copilotproplus"]),
        plan(.grok, "grok.supergrok", "SuperGrok", 30, nil, ["supergrok"]),
        plan(.grok, "grok.heavy", "SuperGrok Heavy", 300, nil, ["supergrokheavy"]),
        plan(.devin, "devin.free", "Free", 0, nil, ["free"]),
        plan(.devin, "devin.pro", "Pro", 20, 1, ["pro"]),
        plan(.devin, "devin.max", "Max", 200, nil, ["max"]),
        // Antigravity has no plan of its own; paid quota comes with Google AI.
        plan(.antigravity, "antigravity.free", "Free", 0, nil, ["free"]),
        plan(.antigravity, "antigravity.aipro", "Google AI Pro", 19.99, 1, ["googleaipro", "aipro"]),
        plan(.antigravity, "antigravity.ultra5x", "Google AI Ultra 5x", 99.99, 5, ["googleaiultra5x", "ultra5x"]),
        plan(.antigravity, "antigravity.ultra20x", "Google AI Ultra 20x", 199.99, 20, ["googleaiultra20x", "ultra20x"]),
        plan(.kiro, "kiro.free", "Free", 0, nil, ["free", "kirofree"]),
        plan(.kiro, "kiro.pro", "Pro", 20, 1, ["pro", "kiropro"]),
        plan(.kiro, "kiro.proplus", "Pro+", 40, 2, ["proplus", "kiroproplus"]),
        plan(.kiro, "kiro.promax", "Pro Max", 100, 5, ["promax", "kiropromax"]),
        plan(.kiro, "kiro.power", "Power", 200, 10, ["power", "kiropower"]),
    ]

    /// Products billed mainly as a subscription. Their connected accounts are
    /// listed even when the plan is missing or unrecognized, so the user can
    /// enter what they pay. Balance and pay-as-you-go APIs (OpenRouter,
    /// DeepSeek, …) stay off the card unless the user adds them by hand.
    static let subscriptionProviders: Set<ProviderQuota.Provider> = [
        .claude, .codex, .cursor, .copilot, .grok, .devin, .windsurf,
        .antigravity, .kiro, .qoder, .augment, .factory,
    ]

    /// Tiers offered in the price editor, cheapest first.
    static func plans(for provider: ProviderQuota.Provider) -> [SubscriptionPlan] {
        plans.filter { $0.provider == provider }
    }

    /// A tier the user chose, only if it belongs to this provider.
    static func plan(id: String, provider: ProviderQuota.Provider) -> SubscriptionPlan? {
        plans.first { $0.id == id && $0.provider == provider }
    }

    static func plan(
        provider: ProviderQuota.Provider,
        planName: String?
    ) -> SubscriptionPlan? {
        guard let key = normalized(planName) else { return nil }
        return plans.first { $0.provider == provider && $0.aliases.contains(key) }
    }

    /// The tier's current catalog name for a source label (`Max 20x` →
    /// `Ultra`, `prolite` → `Pro 5x`); a label the catalog does not know is
    /// shown as the source gave it.
    static func displayName(provider: ProviderQuota.Provider, planName: String?) -> String? {
        plan(provider: provider, planName: planName)?.displayName ?? planName
    }

    /// Names the tier a quota reading was taken under: the tier the user
    /// chose, else the recognized one, else the source's own label. History
    /// stores it so advice never compares percentages across plans.
    static func planKey(
        provider: ProviderQuota.Provider,
        planName: String?,
        chosenPlanID: String?
    ) -> String? {
        let resolved = chosenPlanID.flatMap { Self.plan(id: $0, provider: provider) }
            ?? Self.plan(provider: provider, planName: planName)
        return resolved?.id ?? normalized(planName)
    }

    /// `Max 20x` → `max20x`, `Pro+` → `proplus`, `copilot_pro` → `copilotpro`.
    static func normalized(_ planName: String?) -> String? {
        guard let planName else { return nil }
        let key = planName.lowercased()
            .replacingOccurrences(of: "+", with: "plus")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return key.isEmpty ? nil : key
    }

    private static func plan(
        _ provider: ProviderQuota.Provider,
        _ id: String,
        _ displayName: String,
        _ monthlyUSD: Double,
        _ relativeCapacity: Double?,
        _ aliases: Set<String>
    ) -> SubscriptionPlan {
        SubscriptionPlan(
            id: id,
            provider: provider,
            displayName: displayName,
            monthlyUSD: monthlyUSD,
            relativeCapacity: relativeCapacity,
            aliases: aliases
        )
    }
}

/// What the user told TokenRemain about one account's subscription. Its
/// presence also keeps the account on the cost card, which is how a plan the
/// catalog does not know (or a provider outside `subscriptionProviders`) gets
/// added by hand. Local preference only; never synced.
struct SubscriptionPriceOverride: Codable, Equatable, Sendable {
    static let maximumAmount: Double = 100_000

    /// A catalog tier the user chose, for a source that reports no plan or
    /// the wrong one. Nil keeps the detected plan.
    var planID: String? = nil
    /// Nil keeps the list price of the chosen or detected plan.
    var monthlyAmount: Double?
    /// ISO 4217 code of `monthlyAmount`.
    var currencyCode: String
    /// Paid by someone else (employer, sponsor, trial): listed, not summed.
    var excludesFromTotal: Bool

    var isValid: Bool {
        guard let monthlyAmount else { return true }
        return monthlyAmount.isFinite && monthlyAmount >= 0 && monthlyAmount <= Self.maximumAmount
    }
}

/// One enabled account of a monitored provider. `quota` is nil until the
/// account first answers; such an account only reaches the card through an
/// override, because nothing else says it is a paid subscription.
struct SubscriptionAccountInput: Sendable, Identifiable {
    let accountID: ProviderAccountID
    let provider: ProviderQuota.Provider
    /// Empty for the provider's system account.
    let accountName: String
    let quota: ProviderQuota?

    var id: ProviderAccountID { accountID }
    var isSystem: Bool { accountID == .system(provider) }

    /// A quota re-hosted from an API account (Claude Code over DeepSeek)
    /// describes that API's billing, not a subscription of the host app. An
    /// attribution naming the host itself (the Claude Web source marker) is
    /// still the host's own plan.
    var hostQuota: ProviderQuota? {
        guard let quota else { return nil }
        guard let attribution = quota.attribution else { return quota }
        return attribution.provider == provider ? quota : nil
    }

    var catalogPlan: SubscriptionPlan? {
        SubscriptionPlanCatalog.plan(provider: provider, planName: hostQuota?.planName)
    }
}

struct SubscriptionCostLine: Sendable, Identifiable, Equatable {
    enum PriceSource: Sendable, Equatable {
        case listPrice
        case custom
        case missing
    }

    let accountID: ProviderAccountID
    let provider: ProviderQuota.Provider
    let accountName: String
    let isSystem: Bool
    /// Catalog name when recognized, otherwise the provider's own label.
    let planName: String?
    let catalogPlan: SubscriptionPlan?
    let source: PriceSource
    /// In `currencyCode`; nil when no price is known.
    let amount: Double?
    let currencyCode: String
    /// Nil when no price is known or its currency has no exchange rate.
    let monthlyUSD: Double?
    let isExcluded: Bool
    /// Month-to-date pay-as-you-go spend beyond the plan, when reported.
    let extraUsageUSD: Double?

    var id: ProviderAccountID { accountID }
    var isUnconvertible: Bool { amount != nil && monthlyUSD == nil }
}

/// The card's arithmetic, kept free of views and stores so it is testable.
/// The headline is the recurring subscription total; month-to-date extra
/// usage is reported beside it, never folded into the monthly figure.
struct SubscriptionCostSummary: Sendable, Equatable {
    let lines: [SubscriptionCostLine]

    private var countedLines: [SubscriptionCostLine] {
        lines.filter { !$0.isExcluded }
    }

    var monthlyUSD: Double {
        countedLines.compactMap(\.monthlyUSD).reduce(0, +)
    }

    var extraUsageUSD: Double {
        countedLines.compactMap(\.extraUsageUSD).reduce(0, +)
    }

    var pricedCount: Int {
        countedLines.filter { $0.monthlyUSD != nil }.count
    }

    var missingPriceCount: Int {
        countedLines.filter { $0.source == .missing }.count
    }

    var unconvertibleCount: Int {
        countedLines.filter(\.isUnconvertible).count
    }

    /// The catalog tier this card names for one account, or for a provider
    /// whose accounts all agree: the tier the user chose, else the one
    /// recognized from the source. Nil when unknown or the accounts differ,
    /// so other surfaces never show a tier the card does not.
    func catalogPlanName(for provider: ProviderQuota.Provider, account: ProviderAccountID? = nil) -> String? {
        let names = Set(lines
            .filter { $0.provider == provider && (account == nil || $0.accountID == account) }
            .map { $0.catalogPlan?.displayName })
        guard names.count == 1, let name = names.first ?? nil else { return nil }
        return name
    }

    static func make(
        accounts: [SubscriptionAccountInput],
        overrides: [ProviderAccountID: SubscriptionPriceOverride],
        rates: ExchangeRates?
    ) -> SubscriptionCostSummary {
        let lines = accounts.compactMap { account -> SubscriptionCostLine? in
            let override = overrides[account.accountID].flatMap { $0.isValid ? $0 : nil }
            // A chosen tier from another provider's catalog is ignored.
            let chosenPlan = override?.planID.flatMap {
                SubscriptionPlanCatalog.plan(id: $0, provider: account.provider)
            }
            let plan = chosenPlan ?? account.catalogPlan
            let isSubscription = account.hostQuota != nil
                && (plan != nil || SubscriptionPlanCatalog.subscriptionProviders.contains(account.provider))
            guard override != nil || isSubscription else { return nil }

            let source: SubscriptionCostLine.PriceSource
            let amount: Double?
            let currencyCode: String
            if let custom = override?.monthlyAmount, let override {
                source = .custom
                amount = custom
                currencyCode = override.currencyCode
            } else if let plan {
                source = .listPrice
                amount = plan.monthlyUSD
                currencyCode = DisplayCurrency.usd.rawValue
            } else {
                source = .missing
                amount = nil
                currencyCode = DisplayCurrency.usd.rawValue
            }

            let extraUsage = account.hostQuota?.extraUsage?.spentUSD
            return SubscriptionCostLine(
                accountID: account.accountID,
                provider: account.provider,
                accountName: account.accountName,
                isSystem: account.isSystem,
                planName: plan?.displayName ?? account.quota?.planName,
                catalogPlan: plan,
                source: source,
                amount: amount,
                currencyCode: currencyCode,
                monthlyUSD: amount.flatMap { usd(amount: $0, currencyCode: currencyCode, rates: rates) },
                isExcluded: override?.excludesFromTotal == true,
                extraUsageUSD: extraUsage.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            )
        }
        return SubscriptionCostSummary(lines: lines)
    }

    /// Converts through the shared USD-based rate table. A currency the table
    /// does not carry yields nil, so the line is reported as uncounted rather
    /// than summed at a guessed rate.
    static func usd(amount: Double, currencyCode: String, rates: ExchangeRates?) -> Double? {
        guard amount.isFinite else { return nil }
        let code = currencyCode.uppercased()
        if code == DisplayCurrency.usd.rawValue { return amount }
        guard let currency = DisplayCurrency(rawValue: code),
              let rate = rates?.rate(for: currency),
              rate.isFinite, rate > 0 else {
            return nil
        }
        return amount / rate
    }
}
