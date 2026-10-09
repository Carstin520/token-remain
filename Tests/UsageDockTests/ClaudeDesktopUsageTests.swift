import Foundation
import Testing
@testable import UsageDock

@Suite("Claude desktop usage")
struct ClaudeDesktopUsageTests {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func discoversDefaultsCoworkAndCustomWithoutDuplicates() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let relative = [".claude", ".config/claude", "custom", "Library/Application Support/Claude/local-agent-mode-sessions/a/b/local_c/.claude"]
        for path in relative {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path + "/projects"), withIntermediateDirectories: true)
        }
        let directories = try ClaudeLogDirectories.discover(home: home, environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent("custom").path], additional: [home.appendingPathComponent(".claude").path])
        #expect(directories.count == 4)
        #expect(directories.contains(home.appendingPathComponent(relative[3])))
        #expect(throws: ClaudeLogDirectories.DiscoveryError.self) {
            try ClaudeLogDirectories.discover(home: home, environment: [:], additional: [], maximumEntries: 1)
        }
    }

    @Test func bundledHelperCountsCoworkAndDeduplicatesUnknownPriceTokens() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = home.appendingPathComponent(".claude")
        let cowork = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/a/b/local_c/.claude")
        func record(_ id: Int) -> Data {
            Data("""
            {"type":"assistant","timestamp":"2026-01-10T02:00:00Z","requestId":"fixture-request-\(id)","message":{"id":"fixture-message-\(id)","role":"assistant","model":"fixture-unknown-model","usage":{"input_tokens":101,"output_tokens":202,"cache_creation_input_tokens":303,"cache_read_input_tokens":404}}}
            """.utf8)
        }
        for directory in [cli, cowork] {
            let project = directory.appendingPathComponent("projects/fixture")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try record(1).write(to: project.appendingPathComponent("shared.jsonl"))
        }
        try record(2).write(to: cowork.appendingPathComponent("projects/fixture/cowork.jsonl"))
        let directories = try ClaudeLogDirectories.discover(home: home, environment: [:], additional: [])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent("Vendor/ccusage/20.0.19/darwin-universal/ccusage")
        let output = try await ProcessRunner.run(helper.path,
            arguments: CCUsageService.commandArguments(since: "2026-01-10", timeZone: TimeZone(secondsFromGMT: 0)!),
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin",
                          "CLAUDE_CONFIG_DIR": directories.map(\.path).joined(separator: ","),
                          "CODEX_HOME": home.appendingPathComponent("codex").path,
                          "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
                          "XDG_DATA_HOME": home.appendingPathComponent("data").path])
        let history = try CCUsageService.parseHistory(output)
        let agents = history.days.flatMap(\.agents)
        #expect(agents.count == 1)
        #expect(agents.first?.id == "claude")
        #expect(agents.first?.tokens == 2020)
        #expect(agents.first?.unpricedModels == ["fixture-unknown-model"])
    }

    @Test func cookieParsingRejectsHeaderInjection() throws {
        #expect(try ClaudeWebUsageService.Configuration.decode("a=b; sessionKey=fixture-session; other=c").sessionKey == "fixture-session")
        #expect(throws: ClaudeWebUsageService.ServiceError.self) {
            try ClaudeWebUsageService.Configuration.decode("fixture\r\nInjected: value")
        }
    }

    @Test func webQuotaUsesOnlySelectedOrganizationAndPreservesMissingReset() async throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let quota = try await ClaudeWebUsageService().fetch(configuration: "fixture-session") { request in
            #expect(request.url?.host == "claude.ai")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=fixture-session")
            let payload = request.url!.path == "/api/organizations"
                ? "[{\"uuid\":\"\(id)\",\"capabilities\":[\"chat\"]}]"
                : "{\"five_hour\":{\"utilization\":28},\"seven_day\":{\"utilization\":14}}"
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(quota.primary.usedPercent == 28)
        #expect(quota.primary.resetsAt == nil)
        #expect(quota.attribution?.displayName == "Claude Web")
    }

    @Test func multipleOrganizationsNeverChooseAnArbitraryAccount() async throws {
        do {
            _ = try await ClaudeWebUsageService().fetch(configuration: "fixture-session") { request in
                #expect(request.url!.path == "/api/organizations")
                let data = Data("[{\"uuid\":\"11111111-1111-4111-8111-111111111111\"},{\"uuid\":\"22222222-2222-4222-8222-222222222222\"}]".utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            Issue.record("Expected organization selection")
        } catch ClaudeWebUsageService.ServiceError.organizationRequired {}
    }

    @Test(arguments: [401, 403, 429, 500]) func httpFailuresAreDistinct(status: Int) async throws {
        do {
            _ = try await ClaudeWebUsageService().fetch(configuration: "fixture-session") { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            Issue.record("Expected HTTP failure")
        } catch ClaudeWebUsageService.ServiceError.expired { #expect(status == 401) }
        catch ClaudeWebUsageService.ServiceError.forbidden { #expect(status == 403) }
        catch ClaudeWebUsageService.ServiceError.requestFailed(let code) { #expect(code == status) }
    }

    @Test func timeoutCancelsRequestAndAllowsRetry() async throws {
        do {
            _ = try await ClaudeWebUsageService().fetch(configuration: "fixture-session", timeout: 0.03) { _ in
                try await Task.sleep(for: .seconds(30))
                throw URLError(.unknown)
            }
            Issue.record("Expected timeout")
        } catch is AsyncDeadline.Failure {}
        try await webQuotaUsesOnlySelectedOrganizationAndPreservesMissingReset()
    }

    @Test func cancelledDiscoveryAndRequestDoNotReturnResults() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ClaudeWebUsageService().fetch(configuration: "fixture-session") { _ in
                Issue.record("Pre-cancelled operation reached transport")
                throw URLError(.unknown)
            }
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
    }
}
