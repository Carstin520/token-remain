import Foundation
import Testing
@testable import UsageDock

@Suite("Subscription cost")
struct SubscriptionCostTests {
    private let rates = ExchangeRates(fetchedAt: .now, publishedAt: nil, rates: ["CNY": 8, "EUR": 0.9])

    private func quota(
        _ provider: ProviderQuota.Provider,
        plan: String?,
        extraUSD: Double? = nil,
        attribution: QuotaAttribution? = nil
    ) -> ProviderQuota {
        var quota = ProviderQuota(
            provider: provider,
            primary: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            planName: plan,
            capturedAt: .now
        )
        quota.extraUsage = extraUSD.map { ExtraUsage(spentUSD: $0, monthlyLimitUSD: nil) }
        quota.attribution = attribution
        return quota
    }

    private func account(
        _ provider: ProviderQuota.Provider,
        plan: String?,
        id: ProviderAccountID? = nil,
        extraUSD: Double? = nil,
        attribution: QuotaAttribution? = nil
    ) -> SubscriptionAccountInput {
        SubscriptionAccountInput(
            accountID: id ?? .system(provider),
            provider: provider,
            accountName: id == nil ? "" : "Work",
            quota: quota(provider, plan: plan, extraUSD: extraUSD, attribution: attribution)
        )
    }

    @Test("Plan labels from every source map to one catalog tier")
    func catalogMatchesProviderSpellings() {
        let cases: [(ProviderQuota.Provider, String, String)] = [
            (.claude, "Max 20x", "claude.max20x"),
            (.claude, "Max 5x", "claude.max5x"),
            (.claude, "Pro", "claude.pro"),
            // Codex local logs carry the raw plan type; the API carries the label.
            (.codex, "prolite", "codex.pro5x"),
            (.codex, "Pro 5x", "codex.pro5x"),
            (.codex, "pro", "codex.pro20x"),
            (.codex, "Pro 20x", "codex.pro20x"),
            (.cursor, "Pro_plus", "cursor.proplus"),
            (.cursor, "Pro+", "cursor.proplus"),
            (.copilot, "Copilot Pro", "copilot.pro"),
            (.grok, "SuperGrok", "grok.supergrok"),
        ]
        for (provider, label, id) in cases {
            #expect(SubscriptionPlanCatalog.plan(provider: provider, planName: label)?.id == id, "\(provider) \(label)")
        }
    }

    @Test("Claude's renamed tiers keep their ids and both spellings")
    func claudeRenameKeepsStoredTiers() {
        #expect(SubscriptionPlanCatalog.plan(provider: .claude, planName: "Max 5x")?.displayName == "Max")
        #expect(SubscriptionPlanCatalog.plan(provider: .claude, planName: "Max 20x")?.displayName == "Ultra")
        #expect(SubscriptionPlanCatalog.plan(provider: .claude, planName: "Ultra")?.id == "claude.max20x")
        // Stored overrides and history name the tiers by id, unchanged.
        #expect(SubscriptionPlanCatalog.plan(id: "claude.max5x", provider: .claude)?.monthlyUSD == 100)
        #expect(SubscriptionPlanCatalog.plan(id: "claude.max20x", provider: .claude)?.monthlyUSD == 200)
        // Cards show the current name; labels the catalog lacks stay as given.
        #expect(SubscriptionPlanCatalog.displayName(provider: .claude, planName: "Max 20x") == "Ultra")
        #expect(SubscriptionPlanCatalog.displayName(provider: .claude, planName: "Max") == "Max")
        #expect(SubscriptionPlanCatalog.displayName(provider: .grok, planName: "Grok Bot plan") == "Grok Bot plan")
        #expect(SubscriptionPlanCatalog.displayName(provider: .claude, planName: nil) == nil)
    }

    @Test("Other surfaces read the card's tier per account, or when accounts agree")
    func catalogPlanNameFollowsCard() {
        let work = ProviderAccountID.managed(UUID())
        let summary = SubscriptionCostSummary.make(
            accounts: [account(.claude, plan: nil), account(.claude, plan: "Pro", id: work), account(.codex, plan: "Plus")],
            overrides: [
                .system(.claude): SubscriptionPriceOverride(planID: "claude.max20x", currencyCode: "USD", excludesFromTotal: false),
            ],
            rates: nil
        )

        #expect(summary.catalogPlanName(for: .claude, account: .system(.claude)) == "Ultra")
        #expect(summary.catalogPlanName(for: .claude, account: work) == "Pro")
        #expect(summary.catalogPlanName(for: .claude) == nil)
        #expect(summary.catalogPlanName(for: .codex) == "Plus")
        #expect(summary.catalogPlanName(for: .cursor) == nil)
    }

    @Test("Ambiguous or seat-priced plans are not guessed")
    func catalogLeavesUnknownPlansUnpriced() {
        #expect(SubscriptionPlanCatalog.plan(provider: .claude, planName: "Max") == nil)
        #expect(SubscriptionPlanCatalog.plan(provider: .codex, planName: "Team") == nil)
        #expect(SubscriptionPlanCatalog.plan(provider: .claude, planName: nil) == nil)
        // A tier name only counts for its own provider.
        #expect(SubscriptionPlanCatalog.plan(provider: .openrouter, planName: "Pro") == nil)
    }

    @Test("List prices add up and unknown subscription plans ask for a price")
    func summarizesListPrices() {
        let summary = SubscriptionCostSummary.make(
            accounts: [
                account(.claude, plan: "Max 20x"),
                account(.codex, plan: "prolite"),
                account(.windsurf, plan: "Teams"),
            ],
            overrides: [:],
            rates: nil
        )

        #expect(summary.lines.map(\.provider) == [.claude, .codex, .windsurf])
        #expect(summary.monthlyUSD == 300)
        #expect(summary.pricedCount == 2)
        #expect(summary.missingPriceCount == 1)
        #expect(summary.lines[2].source == .missing)
        #expect(summary.lines[2].planName == "Teams")
    }

    @Test("Balance APIs and re-hosted quotas stay off the card unless added")
    func skipsNonSubscriptions() {
        let route = QuotaAttribution(provider: .deepseek, displayName: "DeepSeek API", routeIdentifier: "deepseek")
        let accounts = [
            account(.openrouter, plan: "Pro"),
            account(.claude, plan: "Pro", attribution: route),
        ]
        #expect(SubscriptionCostSummary.make(accounts: accounts, overrides: [:], rates: nil).lines.isEmpty)

        let added = SubscriptionCostSummary.make(
            accounts: accounts,
            overrides: [.system(.openrouter): SubscriptionPriceOverride(
                monthlyAmount: 15,
                currencyCode: "USD",
                excludesFromTotal: false
            )],
            rates: nil
        )
        #expect(added.lines.map(\.provider) == [.openrouter])
        #expect(added.monthlyUSD == 15)
    }

    @Test("A source marker naming the host provider is still its own plan")
    func claudeWebSourceStaysListed() {
        let claudeWeb = QuotaAttribution(provider: .claude, displayName: "Claude Web", routeIdentifier: "claude-web:org")
        let summary = SubscriptionCostSummary.make(
            accounts: [
                account(.claude, plan: nil, attribution: claudeWeb),
                account(.codex, plan: "Plus", extraUSD: 2,
                        attribution: QuotaAttribution(provider: .codex, displayName: "Codex", routeIdentifier: "codex")),
            ],
            overrides: [:],
            rates: nil
        )

        #expect(summary.lines.map(\.provider) == [.claude, .codex])
        #expect(summary.lines[0].source == .missing)
        #expect(summary.lines[1].monthlyUSD == 20)
        #expect(summary.extraUsageUSD == 2)
    }

    @Test("Every provider's editor tiers are unique and come from its own catalog")
    func editorTiers() {
        let ids = SubscriptionPlanCatalog.plans.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(SubscriptionPlanCatalog.plans(for: .antigravity).map(\.monthlyUSD) == [0, 19.99, 99.99, 199.99])
        #expect(SubscriptionPlanCatalog.plans(for: .kiro).count == 5)
        #expect(SubscriptionPlanCatalog.plans(for: .openrouter).isEmpty)
        #expect(SubscriptionPlanCatalog.plan(id: "claude.max5x", provider: .codex) == nil)
    }

    @Test("A chosen tier prices a source that reports no plan")
    func chosenTierPricesUndetectedPlan() {
        let summary = SubscriptionCostSummary.make(
            accounts: [account(.antigravity, plan: nil), account(.claude, plan: nil)],
            overrides: [
                .system(.antigravity): SubscriptionPriceOverride(
                    planID: "antigravity.aipro",
                    monthlyAmount: nil,
                    currencyCode: "USD",
                    excludesFromTotal: false
                ),
                .system(.claude): SubscriptionPriceOverride(
                    planID: "claude.max5x",
                    monthlyAmount: nil,
                    currencyCode: "USD",
                    excludesFromTotal: false
                ),
            ],
            rates: nil
        )

        #expect(summary.lines.map(\.planName) == ["Google AI Pro", "Max"])
        #expect(summary.lines.allSatisfy { $0.source == .listPrice })
        #expect(summary.monthlyUSD == 119.99)
        #expect(summary.missingPriceCount == 0)
    }

    @Test("A typed amount beats the chosen tier's list price; a foreign tier is ignored")
    func amountBeatsChosenTier() {
        let summary = SubscriptionCostSummary.make(
            accounts: [account(.claude, plan: nil), account(.codex, plan: "Plus")],
            overrides: [
                .system(.claude): SubscriptionPriceOverride(
                    planID: "claude.max20x",
                    monthlyAmount: 180,
                    currencyCode: "USD",
                    excludesFromTotal: false
                ),
                .system(.codex): SubscriptionPriceOverride(
                    planID: "claude.max20x",
                    monthlyAmount: nil,
                    currencyCode: "USD",
                    excludesFromTotal: false
                ),
            ],
            rates: nil
        )

        #expect(summary.lines[0].planName == "Ultra")
        #expect(summary.lines[0].source == .custom)
        #expect(summary.lines[0].monthlyUSD == 180)
        // Codex keeps its detected Plus: a Claude tier cannot price it.
        #expect(summary.lines[1].planName == "Plus")
        #expect(summary.lines[1].monthlyUSD == 20)
    }

    @Test("A custom price wins and converts through the display rate table")
    func customPriceConverts() {
        let summary = SubscriptionCostSummary.make(
            accounts: [account(.cursor, plan: "Pro"), account(.claude, plan: "Pro")],
            overrides: [.system(.cursor): SubscriptionPriceOverride(
                monthlyAmount: 160,
                currencyCode: "CNY",
                excludesFromTotal: false
            )],
            rates: rates
        )

        #expect(summary.lines[0].source == .custom)
        #expect(summary.lines[0].amount == 160)
        #expect(summary.lines[0].monthlyUSD == 20)
        #expect(summary.monthlyUSD == 40)
    }

    @Test("A currency without a rate is reported, not summed at a guess")
    func unconvertibleCustomPrice() {
        let summary = SubscriptionCostSummary.make(
            accounts: [account(.cursor, plan: "Pro")],
            overrides: [.system(.cursor): SubscriptionPriceOverride(
                monthlyAmount: 144,
                currencyCode: "CNY",
                excludesFromTotal: false
            )],
            rates: nil
        )

        #expect(summary.lines[0].isUnconvertible)
        #expect(summary.monthlyUSD == 0)
        #expect(summary.unconvertibleCount == 1)
        #expect(summary.pricedCount == 0)
    }

    @Test("Excluded rows and their extra usage stay out of the totals")
    func excludedRows() {
        let work = ProviderAccountID.managed(UUID())
        let summary = SubscriptionCostSummary.make(
            accounts: [
                account(.claude, plan: "Max 5x", extraUSD: 12.5),
                account(.claude, plan: "Max 20x", id: work, extraUSD: 40),
            ],
            overrides: [work: SubscriptionPriceOverride(
                monthlyAmount: nil,
                currencyCode: "USD",
                excludesFromTotal: true
            )],
            rates: nil
        )

        #expect(summary.lines.count == 2)
        #expect(summary.lines[1].isExcluded)
        // Excluding keeps the list price visible on the row.
        #expect(summary.lines[1].monthlyUSD == 200)
        #expect(summary.monthlyUSD == 100)
        #expect(summary.extraUsageUSD == 12.5)
    }

    @Test("Extra usage is reported beside the monthly total, not inside it")
    func extraUsageSeparate() {
        let summary = SubscriptionCostSummary.make(
            accounts: [account(.copilot, plan: "Copilot Pro", extraUSD: 3.2)],
            overrides: [:],
            rates: nil
        )
        #expect(summary.monthlyUSD == 10)
        #expect(summary.extraUsageUSD == 3.2)
    }

    @Test("An invalid stored amount is ignored")
    func invalidOverrideIgnored() {
        let summary = SubscriptionCostSummary.make(
            accounts: [account(.claude, plan: "Pro")],
            overrides: [.system(.claude): SubscriptionPriceOverride(
                monthlyAmount: -5,
                currencyCode: "USD",
                excludesFromTotal: false
            )],
            rates: nil
        )
        #expect(summary.lines[0].source == .listPrice)
        #expect(summary.monthlyUSD == 20)
    }

    @Test("Overrides persist per account and clear back to the list price")
    @MainActor
    func storePersistsOverrides() throws {
        let suite = "subscription-cost-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = ProviderAccountID.managed(UUID())
        let value = SubscriptionPriceOverride(planID: "claude.pro", monthlyAmount: 140, currencyCode: "CNY", excludesFromTotal: false)

        let store = SubscriptionCostStore(defaults: defaults)
        store.setOverride(value, for: work)
        store.setOverride(
            SubscriptionPriceOverride(monthlyAmount: .infinity, currencyCode: "USD", excludesFromTotal: false),
            for: .system(.claude)
        )

        let reloaded = SubscriptionCostStore(defaults: defaults)
        #expect(reloaded.overrides == [work: value])

        reloaded.setOverride(nil, for: work)
        #expect(SubscriptionCostStore(defaults: defaults).overrides.isEmpty)
    }
}
