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
}
