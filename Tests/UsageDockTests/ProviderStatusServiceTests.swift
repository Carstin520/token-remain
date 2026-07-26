import Foundation
import Testing
@testable import UsageDock

@Suite("Official provider status")
struct ProviderStatusServiceTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Codex aggregation ignores unrelated OpenAI incidents")
    func codexComponentAggregation() throws {
        let data = Data(
            #"{"components":[{"name":"Conversations","status":"major_outage"},{"name":"Codex API","status":"operational"},{"name":"CLI","status":"degraded_performance"},{"name":"VS Code extension","status":"operational"},{"name":"Codex Web","status":"operational"},{"name":"Codex in ChatGPT Desktop","status":"operational"}]}"#.utf8
        )
        let page = try #require(URL(string: "https://status.openai.com"))

        let status = try ProviderStatusParser.parse(
            data,
            provider: .codex,
            checkedAt: checkedAt,
            statusPageURL: page
        )

        #expect(status.level == .degradedPerformance)
        #expect(status.isAbnormal)
        #expect(status.affectedComponentNames == ["CLI"])
        #expect(!status.componentNames.contains("Conversations"))
    }

    @Test("Claude Code and API use the worst relevant component")
    func claudeComponentAggregation() throws {
        let data = Data(
            #"{"components":[{"name":"claude.ai","status":"major_outage"},{"name":"Claude API (api.anthropic.com)","status":"operational"},{"name":"Claude Code","status":"partial_outage"},{"name":"Claude Cowork","status":"degraded_performance"}]}"#.utf8
        )
        let page = try #require(URL(string: "https://status.claude.com"))

        let status = try ProviderStatusParser.parse(
            data,
            provider: .claude,
            checkedAt: checkedAt,
            statusPageURL: page
        )

        #expect(status.level == .partialOutage)
        #expect(status.affectedComponentNames == ["Claude Code"])
        #expect(status.componentNames == ["Claude API (api.anthropic.com)", "Claude Code"])
    }

    @Test("Missing relevant components is unknown, not an outage")
    func missingComponentsAreUnknown() throws {
        let data = Data(#"{"components":[{"name":"Images","status":"major_outage"}]}"#.utf8)
        let page = try #require(URL(string: "https://status.openai.com"))

        let status = try ProviderStatusParser.parse(
            data,
            provider: .codex,
            checkedAt: checkedAt,
            statusPageURL: page
        )

        #expect(status.level == .unknown)
        #expect(!status.isAbnormal)
        #expect(status.componentNames.isEmpty)
    }

    @Test("Statuspage values map to the intended alert contract")
    func levelMapping() {
        #expect(ProviderServiceStatus.Level.statusPageValue("operational") == .operational)
        #expect(ProviderServiceStatus.Level.statusPageValue("degraded_performance") == .degradedPerformance)
        #expect(ProviderServiceStatus.Level.statusPageValue("partial_outage") == .partialOutage)
        #expect(ProviderServiceStatus.Level.statusPageValue("major_outage") == .majorOutage)
        #expect(ProviderServiceStatus.Level.statusPageValue("under_maintenance") == .maintenance)
        #expect(ProviderServiceStatus.Level.statusPageValue("new_status") == .unknown)
        #expect(!ProviderServiceStatus.Level.unknown.isAbnormal)
        #expect(ProviderServiceStatus.Level.maintenance.isAbnormal)
    }

    @Test("Every provider status level has localized explanatory copy")
    func statusExplanationCoverage() {
        let keys = ProviderServiceStatus.Level.allCases.map(\.explanationLocalizationKey)
        #expect(Set(keys).count == ProviderServiceStatus.Level.allCases.count)
        for key in keys {
            #expect(L10n.text(key) != key)
        }
    }

    @Test("Menu-bar popover hides healthy status and keeps provider incidents")
    func popoverVisibilityContract() throws {
        let page = try #require(URL(string: "https://status.openai.com"))
        let healthy = ProviderServiceStatus(
            provider: .codex,
            level: .operational,
            componentNames: ["Codex API"],
            affectedComponentNames: [],
            checkedAt: checkedAt,
            statusPageURL: page
        )
        let incident = ProviderServiceStatus(
            provider: .codex,
            level: .partialOutage,
            componentNames: ["Codex API"],
            affectedComponentNames: ["Codex API"],
            checkedAt: checkedAt,
            statusPageURL: page
        )

        #expect(PopoverQuotaWidget.visibleServiceStatus(healthy) == nil)
        #expect(PopoverQuotaWidget.visibleServiceStatus(incident) == incident)
        #expect(PopoverQuotaWidget.visibleServiceStatus(nil) == nil)
    }
}
