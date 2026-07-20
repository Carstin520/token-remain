import Foundation
import Testing
@testable import UsageDock

@Suite("Usage pace")
struct UsagePaceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    @Test("Even consumption is on track and lasts until reset")
    func onTrack() throws {
        let pace = try #require(UsagePace(
            window: QuotaWindow(
                usedPercent: 50,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(week / 2)
            ),
            now: now
        ))

        #expect(pace.status == .onTrack)
        #expect(pace.expectedUsedPercent == 50)
        #expect(pace.willLastUntilReset)
        #expect(pace.estimatedRunOutAt == nil)
        #expect(!pace.showsRemainingWarning)
    }

    @Test("Fast consumption projects depletion before reset")
    func projectedRunOut() throws {
        let pace = try #require(UsagePace(
            window: QuotaWindow(
                usedPercent: 80,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(week / 2)
            ),
            now: now
        ))

        #expect(pace.status == .deficit)
        #expect(pace.deltaPercent == 30)
        #expect(!pace.willLastUntilReset)
        #expect(pace.estimatedRunOutAt == now.addingTimeInterval(21 * 60 * 60))
        #expect(pace.showsRemainingWarning)
    }

    @Test("Slow consumption reports reserve and lasts until reset")
    func reserve() throws {
        let pace = try #require(UsagePace(
            window: QuotaWindow(
                usedPercent: 20,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(week / 2)
            ),
            now: now
        ))

        #expect(pace.status == .reserve)
        #expect(pace.deltaPercent == -30)
        #expect(pace.willLastUntilReset)
        #expect(!pace.showsRemainingWarning)
    }

    @Test("Projection waits for reset metadata and a stable sample")
    func unavailableWithoutEnoughContext() {
        #expect(UsagePace(
            window: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil),
            now: now
        ) == nil)

        #expect(UsagePace(
            window: QuotaWindow(
                usedPercent: 20,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(week * 0.99)
            ),
            now: now
        ) == nil)
    }
}
