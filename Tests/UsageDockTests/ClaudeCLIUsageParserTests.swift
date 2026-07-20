import Foundation
import Testing
@testable import UsageDock

@Suite("Claude CLI usage parser")
struct ClaudeCLIUsageParserTests {
    @Test("Parses the current Claude usage screen in reading order")
    func parsesCurrentClaudeUsageScreenByReadingOrder() throws {
        let output = """
        Claude Code v2.1.201
        Total cost: $0.0000
        Current session
        4% used
        Resets 11:50pm (Asia/Shanghai) │
        Current week (all models)
        0%used
        Resets Jul 24 at 1pm (Asia/Shanghai)
        Current week (Fable)
        0% used
        """
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-17T10:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8), now: now, calendar: calendar)

        #expect(quota.primary.usedPercent == 4)
        #expect(quota.secondary?.usedPercent == 0)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.windowMinutes == 10_080)
        #expect(quota.primary.resetsAt != nil)
        #expect(
            quota.secondary?.resetsAt
                == ISO8601DateFormatter().date(from: "2026-07-24T05:00:00Z")
        )
    }

    @Test("Converts remaining percentages to used percentages")
    func convertsRemainingPercentToUsedPercent() throws {
        let output = """
        Current session
        95% left
        Resets 6pm
        Current week
        80% remaining
        Resets Jul 24
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

        #expect(quota.primary.usedPercent == 5)
        #expect(quota.secondary?.usedPercent == 20)
    }

    @Test("Ignores promotional percentages without a usage direction")
    func ignoresPromotionalPercentWithoutUsageDirection() throws {
        let output = """
        Weekly rate limits are 50% higher through July 19.
        Current session
        12% used
        Resets 9pm
        Current week
        34% used
        Resets Jul 24 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

        #expect(quota.primary.usedPercent == 12)
        #expect(quota.secondary?.usedPercent == 34)
    }

    @Test("Matches reset times by window shape when terminal rows are reordered")
    func matchesResetTimesByWindowShape() throws {
        let output = """
        Current session
        8% used
        Current week
        1% used
        Resets Jul 24 at 1pm
        Current week (Fable)
        Resets Jul 24 at 1pm
        """

        let quota = try ClaudeCLIUsageParser.parse(Data(output.utf8))

        #expect(quota.primary.resetsAt == nil)
        #expect(quota.secondary?.resetsAt != nil)
    }
}
