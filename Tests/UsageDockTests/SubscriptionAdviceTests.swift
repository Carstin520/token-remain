import Foundation
import Testing
@testable import UsageDock

@Suite("Subscription advice")
struct SubscriptionAdviceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week = 10_080

    private func line(_ provider: ProviderQuota.Provider, plan: String?) -> SubscriptionCostLine {
        let input = SubscriptionAccountInput(
            accountID: .system(provider),
            provider: provider,
            accountName: "",
            quota: quota(provider, plan: plan, short: 0, long: nil)
        )
        return SubscriptionCostSummary.make(accounts: [input], overrides: [:], rates: nil).lines[0]
    }

    private func quota(
        _ provider: ProviderQuota.Provider,
        plan: String?,
        short: Double?,
        long: (used: Double, elapsed: Double, minutes: Int)?
    ) -> ProviderQuota {
        let longWindow = long.map {
            QuotaWindow(
                usedPercent: $0.used,
                windowMinutes: $0.minutes,
                resetsAt: now.addingTimeInterval(TimeInterval($0.minutes) * 60 * (1 - $0.elapsed))
            )
        }
        let shortWindow = short.map {
            QuotaWindow(usedPercent: $0, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600))
        }
        return ProviderQuota(
            provider: provider,
            primary: shortWindow ?? longWindow!,
            secondary: shortWindow == nil ? nil : longWindow,
            planName: plan,
            capturedAt: now
        )
    }

    /// Two completed five-hour windows a day for `days` days, each peaking at `peak`.
    private func shortHistory(_ provider: ProviderQuota.Provider, days: Int, peak: Double) -> [QuotaUsageHistory.Sample] {
        (0..<days).flatMap { day -> [QuotaUsageHistory.Sample] in
            [8.0, 16.0].map { hour in
                let reset = now.addingTimeInterval(-Double(day) * 86_400 - hour * 3_600)
                return QuotaUsageHistory.Sample(
                    provider: provider,
                    usedPercent: peak,
                    windowMinutes: 300,
                    resetsAt: reset,
                    capturedAt: reset.addingTimeInterval(-1_800)
                )
            }
        }
    }

    @Test("A weekly window running out suggests the next tier with its price change")
    func upgradesOnWeeklyCap() {
        let advice = SubscriptionAdvisor.advise(
            line: line(.codex, plan: "Plus"),
            quota: quota(.codex, plan: "Plus", short: 40, long: (100, 0.6, week)),
            samples: [],
            now: now
        )

        #expect(advice.kind == .upgrade(SubscriptionPlanCatalog.plan(id: "codex.pro5x", provider: .codex)))
        #expect(advice.monthlyDeltaUSD == 80)
        guard case .longWindow(let minutes, let percent, let isProjection)? = advice.evidence.first else {
            Issue.record("Expected the weekly window as evidence")
            return
        }
        #expect(minutes == week && isProjection)
        #expect(abs(percent - 100 / 0.6) < 0.01)
    }

    @Test("Hitting the five-hour cap several times a week suggests upgrading")
    func upgradesOnRepeatedShortHits() {
        let advice = SubscriptionAdvisor.advise(
            line: line(.claude, plan: "Pro"),
            quota: quota(.claude, plan: "Pro", short: 30, long: (40, 0.5, week)),
            samples: shortHistory(.claude, days: 7, peak: 100),
            now: now
        )

        #expect(advice.kind == .upgrade(SubscriptionPlanCatalog.plan(id: "claude.max5x", provider: .claude)))
        #expect(advice.evidence.contains { if case .shortLimitHits = $0 { true } else { false } })
    }

    @Test("Running out on the top tier names no target")
    func topTierHasNoTarget() {
        let advice = SubscriptionAdvisor.advise(
            line: line(.claude, plan: "Max 20x"),
            quota: quota(.claude, plan: "Max 20x", short: 20, long: (97, 0.9, week)),
            samples: [],
            now: now
        )
        #expect(advice.kind == .upgrade(nil))
        #expect(advice.monthlyDeltaUSD == nil)
    }

    @Test("Light use over enough history suggests the cheapest tier that still fits")
    func downgradesWithHeadroom() {
        let advice = SubscriptionAdvisor.advise(
            line: line(.claude, plan: "Max 20x"),
            quota: quota(.claude, plan: "Max 20x", short: 5, long: (10, 0.7, week)),
            samples: shortHistory(.claude, days: 12, peak: 15),
            now: now
        )

        // Busiest window 15% × 20 / 5 = 60% on Max 5x; Pro would be 300%.
        #expect(advice.kind == .downgrade(SubscriptionPlanCatalog.plan(id: "claude.max5x", provider: .claude)!))
        #expect(advice.monthlyDeltaUSD == -100)
    }

    @Test("Light use without enough history keeps the plan")
    func keepsWithoutEnoughHistory() {
        let advice = SubscriptionAdvisor.advise(
            line: line(.claude, plan: "Max 20x"),
            quota: quota(.claude, plan: "Max 20x", short: 5, long: (10, 0.7, week)),
            samples: shortHistory(.claude, days: 4, peak: 15),
            now: now
        )
        #expect(advice.kind == .keep)
    }

    @Test("An idle billing month suggests cancelling; month lengths match loosely")
    func cancelsIdleMonthlyPlan() {
        let previousCycle = QuotaUsageHistory.Sample(
            provider: .cursor,
            usedPercent: 1,
            windowMinutes: 44_640,
            resetsAt: now.addingTimeInterval(-10 * 86_400),
            capturedAt: now.addingTimeInterval(-11 * 86_400)
        )
        let advice = SubscriptionAdvisor.advise(
            line: line(.cursor, plan: "Pro"),
            quota: quota(.cursor, plan: "Pro", short: nil, long: (0, 0.3, 43_200)),
            samples: [previousCycle],
            now: now
        )
        #expect(advice.kind == .cancel)
        #expect(advice.monthlyDeltaUSD == -20)
    }

    @Test("No reading means no advice")
    func insufficientWithoutQuota() {
        let advice = SubscriptionAdvisor.advise(line: line(.claude, plan: "Pro"), quota: nil, samples: [], now: now)
        #expect(advice == .insufficient)
    }

    @Test("The headline sums suggested changes, or says the plans fit")
    func summarizes() {
        let upgrade = SubscriptionAdvice(kind: .upgrade(nil), evidence: [], monthlyDeltaUSD: 80)
        let downgrade = SubscriptionAdvice(
            kind: .downgrade(SubscriptionPlanCatalog.plan(id: "cursor.pro", provider: .cursor)!),
            evidence: [],
            monthlyDeltaUSD: -40
        )
        let keep = SubscriptionAdvice(kind: .keep, evidence: [], monthlyDeltaUSD: nil)

        #expect(SubscriptionAdviceSummary([upgrade, downgrade, keep]).state == .changes(count: 2, netMonthlyDeltaUSD: 40))
        #expect(SubscriptionAdviceSummary([keep, .insufficient]).state == .allFit)
        #expect(SubscriptionAdviceSummary([.insufficient]).state == .insufficientData)
    }
}
