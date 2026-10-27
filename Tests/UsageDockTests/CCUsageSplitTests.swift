import Foundation
import Testing
@testable import UsageDock

@Suite("ccusage Codex split")
struct CCUsageSplitTests {
    private typealias Report = CCUsageService.Report

    private static func agent(_ id: String, tokens: Int64, cost: Double = 1) -> Report.Agent {
        Report.Agent(
            agent: id,
            totalTokens: tokens,
            totalCost: cost,
            modelsUsed: ["fixture-model"],
            modelBreakdowns: nil
        )
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccusage-split-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Halves merge per day in the unified report's agent order")
    func mergeKeepsOrderAndDays() {
        let others = Report(daily: [
            Report.Row(period: "2027-01-01", agents: [Self.agent("claude", tokens: 10)]),
            Report.Row(period: "2027-01-02", agents: [
                Self.agent("claude", tokens: 20),
                Self.agent("opencode", tokens: 5)
            ])
        ])
        let codex = Report(daily: [
            Report.Row(period: "2027-01-02", agents: [Self.agent("codex", tokens: 7)]),
            Report.Row(period: "2027-01-03", agents: [Self.agent("codex", tokens: 9)])
        ])

        let merged = CCUsageService.merged(others: others, codex: codex)

        #expect(merged.daily.map(\.period) == ["2027-01-01", "2027-01-02", "2027-01-03"])
        #expect(merged.daily[0].agents?.map(\.agent) == ["claude"])
        #expect(merged.daily[1].agents?.map(\.agent) == ["claude", "codex", "opencode"])
        #expect(merged.daily[2].agents?.map(\.agent) == ["codex"])
    }

    @Test("Each agent comes from its own half only, so nothing is counted twice")
    func mergeDropsCrossedEntries() {
        let others = Report(daily: [Report.Row(period: "2027-01-01", agents: [
            Self.agent("claude", tokens: 10),
            Self.agent("codex", tokens: 999)
        ])])
        let codex = Report(daily: [Report.Row(period: "2027-01-01", agents: [
            Self.agent("Codex", tokens: 7),
            Self.agent("claude", tokens: 999)
        ])])

        let agents = CCUsageService.merged(others: others, codex: codex).daily.first?.agents
        #expect(agents?.map(\.agent) == ["claude", "Codex"])
        #expect(agents?.map(\.totalTokens) == [10, 7])
    }

    @Test("The Codex half sees no other agent and the other half no Codex")
    func splitEnvironmentsIsolateAgents() throws {
        let isolation = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: isolation) }
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        let invocation = CCUsageService.Invocation(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["daily"],
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "CLAUDE_CONFIG_DIR": "/Users/fixture/.claude",
                "XDG_DATA_HOME": "/Users/fixture/data",
                "GEMINI_DATA_DIR": "/Users/fixture/gemini"
            ],
            claudeDirectories: [],
            pricingConfigurationURL: nil
        )

        let split = try #require(CCUsageService.splitEnvironments(
            for: invocation,
            home: home,
            isolationDirectory: isolation
        ))
        #expect(split.others["CODEX_HOME"] == isolation.path)
        #expect(split.others["CLAUDE_CONFIG_DIR"] == "/Users/fixture/.claude")
        #expect(split.codex == [
            "HOME": isolation.path,
            "CODEX_HOME": "/Users/fixture/.codex",
            "PATH": "/usr/bin:/bin"
        ])

        try Data("x".utf8).write(to: isolation.appending(path: "not-empty"))
        #expect(CCUsageService.splitEnvironments(
            for: invocation,
            home: home,
            isolationDirectory: isolation
        ) == nil)
    }

    @Test("A configured Codex home is the one the Codex half reads")
    func splitHonorsCodexHome() throws {
        let isolation = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: isolation) }
        let invocation = CCUsageService.Invocation(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["daily"],
            environment: ["CODEX_HOME": "/Volumes/work/codex"],
            claudeDirectories: [],
            pricingConfigurationURL: nil
        )
        let split = try #require(CCUsageService.splitEnvironments(
            for: invocation,
            isolationDirectory: isolation
        ))
        #expect(split.codex["CODEX_HOME"] == "/Volumes/work/codex")
        #expect(split.others["CODEX_HOME"] == isolation.path)
    }

    @Test("Vendored ccusage: the merged halves equal one full report")
    func vendoredHelperSplitMatchesFullReport() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil
        ) as? [String: Any]
        let helperVersion = try #require(info?["TokenRemainBundledCCUsageVersion"] as? String)
        let executable = root.appending(path: "Vendor/ccusage/\(helperVersion)/darwin-universal/ccusage")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))

        let home = try Self.makeDirectory()
        let isolation = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: isolation)
        }
        let claudeLog = home.appending(path: ".claude/projects/fixture/session.jsonl")
        let codexLog = home.appending(
            path: ".codex/sessions/2026/01/10/rollout-2026-01-10T02-00-00-11111111-2222-4333-8444-555555555555.jsonl"
        )
        for url in [claudeLog, codexLog] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data(#"""
        {"type":"assistant","timestamp":"2026-01-10T02:00:00Z","requestId":"fixture-request","message":{"id":"fixture-message","role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":101,"output_tokens":202,"cache_creation_input_tokens":303,"cache_read_input_tokens":404}}}

        """#.utf8).write(to: claudeLog)
        try Data(#"""
        {"timestamp":"2026-01-10T02:00:00.000Z","type":"session_meta","payload":{"id":"11111111-2222-4333-8444-555555555555","timestamp":"2026-01-10T02:00:00.000Z","cwd":"/tmp","originator":"codex_cli_rs","cli_version":"0.50.0"}}
        {"timestamp":"2026-01-10T02:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp","model":"gpt-5"}}
        {"timestamp":"2026-01-10T02:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":300,"reasoning_output_tokens":50,"total_tokens":1300},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":300,"reasoning_output_tokens":50,"total_tokens":1300},"model_context_window":200000}}}

        """#.utf8).write(to: codexLog)

        let invocation = CCUsageService.Invocation(
            executable: executable,
            arguments: CCUsageService.commandArguments(
                since: "2026-01-10",
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
            claudeDirectories: [],
            pricingConfigurationURL: nil
        )
        let service = CCUsageService()
        let split = try #require(CCUsageService.splitEnvironments(
            for: invocation,
            home: home,
            isolationDirectory: isolation
        ))

        let full = try await service.runReport(invocation, environment: invocation.environment)
        let others = try await service.runReport(invocation, environment: split.others)
        let codex = try await service.runReport(invocation, environment: split.codex)

        // Guards the fixture itself, so an empty report cannot pass.
        #expect(full.daily.flatMap { $0.agents ?? [] }.map(\.agent) == ["claude", "codex"])
        #expect(others.daily.flatMap { $0.agents ?? [] }.map(\.agent) == ["claude"])
        #expect(codex.daily.flatMap { $0.agents ?? [] }.map(\.agent) == ["codex"])
        #expect(CCUsageService.merged(others: others, codex: codex) == full)
    }
}
