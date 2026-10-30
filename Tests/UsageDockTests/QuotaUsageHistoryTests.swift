import Foundation
import Testing
@testable import UsageDock

@Suite("Quota usage history")
struct QuotaUsageHistoryTests {
    private func quota(
        _ provider: ProviderQuota.Provider,
        used: Double,
        windowMinutes: Int = 300,
        at date: Date
    ) -> ProviderQuota {
        ProviderQuota(
            provider: provider,
            primary: QuotaWindow(
                usedPercent: used,
                windowMinutes: windowMinutes,
                resetsAt: date.addingTimeInterval(3_600)
            ),
            secondary: nil,
            planName: nil,
            capturedAt: date
        )
    }

    @Test("Every provider can contribute its primary quota window")
    func recordsEveryProvider() {
        let now = Date(timeIntervalSince1970: 10_000)
        var history = QuotaUsageHistory.empty

        for (index, provider) in ProviderQuota.Provider.displayOrder.enumerated() {
            history = history.recording(
                quota(provider, used: Double(index), at: now.addingTimeInterval(Double(index)))
            )
        }

        #expect(history.providers == ProviderQuota.Provider.displayOrder)
        #expect(history.samples.count == ProviderQuota.Provider.displayOrder.count)
        #expect(history.samples(for: .cursor).first?.windowMinutes == 300)
        #expect(history.samples(for: .antigravity).first?.provider == .antigravity)
    }

    @Test("Repeated refreshes replace the same provider's fifteen-minute bucket")
    func coalescesBucket() {
        let start = Date(timeIntervalSince1970: 1_800)
        let history = QuotaUsageHistory.empty
            .recording(quota(.cursor, used: 20, at: start))
            .recording(quota(.cursor, used: 28, at: start.addingTimeInterval(120)))
            .recording(quota(.cursor, used: 35, at: start.addingTimeInterval(901)))

        let samples = history.samples(for: .cursor)
        #expect(samples.count == 2)
        #expect(samples.first?.usedPercent == 28)
        #expect(samples.last?.usedPercent == 35)
    }

    @Test("Percentages clamp and samples older than retention are pruned")
    func clampsAndPrunes() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = old.addingTimeInterval(QuotaUsageHistory.retentionDuration + 60)
        let history = QuotaUsageHistory.empty
            .recording(quota(.claude, used: -10, at: old))
            .recording(quota(.antigravity, used: 120, at: recent))

        #expect(history.samples.count == 1)
        #expect(history.samples.first?.provider == .antigravity)
        #expect(history.samples.first?.usedPercent == 100)
    }

    @Test("A cache written before accounts and weekly windows still decodes")
    func decodesLegacyCache() throws {
        let legacy = #"""
        {"samples":[{"provider":"Claude Code","usedPercent":42,"windowMinutes":300,"capturedAt":1000}]}
        """#
        let history = try JSONDecoder().decode(QuotaUsageHistory.self, from: Data(legacy.utf8))

        #expect(history.samples.count == 1)
        #expect(history.samples.first?.accountID == nil)
        #expect(history.samples.first?.secondary == nil)
        #expect(history.samples(for: .claude).count == 1)
    }

    @Test("Managed accounts get their own series and stay out of the trend table")
    func recordsManagedAccountsSeparately() {
        let now = Date(timeIntervalSince1970: 1_800)
        let work = ProviderAccountID.managed(UUID())
        let history = QuotaUsageHistory.empty
            .recording(quota(.claude, used: 20, at: now))
            .recording(quota(.claude, used: 70, at: now.addingTimeInterval(60)), account: work)
            .recording(quota(.codex, used: 5, at: now), account: ProviderAccountID.managed(UUID()))

        // Same provider and bucket, different accounts: neither replaces the other.
        #expect(history.samples.count == 1)
        #expect(history.accountSamples?.count == 2)
        #expect(history.samples(for: .claude).map(\.usedPercent) == [20])
        #expect(history.samples(for: .claude, account: work).map(\.usedPercent) == [70])
        // Passing the system ID reads the legacy nil-account series.
        #expect(history.samples(for: .claude, account: .system(.claude)).map(\.usedPercent) == [20])
        #expect(history.providers == [.claude])
        #expect(Set((history.samples + (history.accountSamples ?? [])).map(\.id)).count == 3)
    }

    @Test("Older builds reading the shared cache never see managed-account samples")
    func managedSamplesStayOutOfLegacyKey() throws {
        let now = Date(timeIntervalSince1970: 1_800)
        let history = QuotaUsageHistory.empty
            .recording(quota(.claude, used: 20, at: now))
            .recording(quota(.claude, used: 70, at: now), account: ProviderAccountID.managed(UUID()))
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any]
        )
        let legacy = try #require(object["samples"] as? [[String: Any]])

        // The key an older build decodes holds only the system series.
        #expect(legacy.count == 1)
        #expect(legacy.allSatisfy { $0["accountID"] == nil })
        #expect((object["accountSamples"] as? [[String: Any]])?.count == 1)
    }

    @Test("The system account ID is stored as the legacy nil series")
    func systemAccountStoresAsNil() {
        let now = Date(timeIntervalSince1970: 1_800)
        let history = QuotaUsageHistory.empty
            .recording(quota(.claude, used: 20, at: now))
            .recording(quota(.claude, used: 30, at: now.addingTimeInterval(60)), account: .system(.claude))

        #expect(history.samples.count == 1)
        #expect(history.samples.first?.accountID == nil)
        #expect(history.samples.first?.usedPercent == 30)
    }

    @Test("Each sample keeps the plan it was taken under")
    func recordsPlanKey() {
        let history = QuotaUsageHistory.empty
            .recording(quota(.claude, used: 20, at: Date(timeIntervalSince1970: 1_800)), planKey: "claude.max20x")
        #expect(history.samples.first?.planKey == "claude.max20x")
        // A chosen tier wins over the source's label; an unknown label is kept as-is.
        #expect(SubscriptionPlanCatalog.planKey(provider: .claude, planName: "Pro", chosenPlanID: "claude.max5x") == "claude.max5x")
        #expect(SubscriptionPlanCatalog.planKey(provider: .claude, planName: "Max 20x", chosenPlanID: nil) == "claude.max20x")
        #expect(SubscriptionPlanCatalog.planKey(provider: .windsurf, planName: "Teams", chosenPlanID: nil) == "teams")
        #expect(SubscriptionPlanCatalog.planKey(provider: .claude, planName: nil, chosenPlanID: "codex.plus") == nil)
    }

    @Test("The weekly window is recorded beside the primary one")
    func recordsSecondaryWindow() {
        let now = Date(timeIntervalSince1970: 1_800)
        let reset = now.addingTimeInterval(86_400)
        let quota = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 140, windowMinutes: 10_080, resetsAt: reset),
            planName: "Max 5x",
            capturedAt: now
        )
        let sample = QuotaUsageHistory.empty.recording(quota).samples.first

        #expect(sample?.secondary == QuotaUsageHistory.WindowReading(
            usedPercent: 100,
            windowMinutes: 10_080,
            resetsAt: reset
        ))
    }

    @Test("The cache contains display values only and round-trips every provider")
    func cacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-history-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = QuotaUsageHistory.empty
            .recording(quota(.cursor, used: 42, windowMinutes: 43_200, at: Date(timeIntervalSince1970: 2_000)))
            .recording(quota(.antigravity, used: 17, at: Date(timeIntervalSince1970: 3_000)))
        let cache = QuotaUsageHistoryCache(url: url)
        cache.save(source)

        #expect(cache.load() == source)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.localizedCaseInsensitiveContains("token"))
        #expect(!raw.localizedCaseInsensitiveContains("email"))
    }

    @Test("Writes coalesce to the newest history and flush on demand")
    func writerCoalescesAndFlushes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-history-writer-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = QuotaUsageHistoryCache(url: url)
        let writer = QuotaUsageHistoryWriter(cache: cache, writeDelay: 3_600)

        let first = QuotaUsageHistory.empty
            .recording(quota(.cursor, used: 10, at: Date(timeIntervalSince1970: 2_000)))
        let second = first
            .recording(quota(.cursor, used: 20, at: Date(timeIntervalSince1970: 2_060)))
        writer.schedule(first)
        writer.schedule(second)
        // Nothing reaches disk inside the coalescing window.
        #expect(cache.load() == nil)

        writer.flush()
        #expect(cache.load() == second)
    }

    @Test("A zero delay writes through immediately")
    func writerWritesThroughWithoutDelay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-history-writer-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = QuotaUsageHistoryCache(url: url)
        let history = QuotaUsageHistory.empty
            .recording(quota(.antigravity, used: 33, at: Date(timeIntervalSince1970: 4_000)))

        QuotaUsageHistoryWriter(cache: cache, writeDelay: 0).schedule(history)
        #expect(cache.load() == history)
    }
}
