import Foundation
import Testing
@testable import UsageDock

@Suite("Codex usage service")
struct CodexUsageServiceTests {
    @Test("Canonical Codex quota wins over a newer model-specific limit")
    func canonicalQuotaWinsOverNewerModelLimit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T11:35:06.513Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 31,
                windowMinutes: 10_080
            )
        ], to: root.appendingPathComponent("general.jsonl"))
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T11:35:24.973Z",
                limitID: "codex_bengalfox",
                limitName: "GPT-5.3-Codex-Spark",
                planType: nil,
                usedPercent: 0,
                windowMinutes: 10_080
            )
        ], to: root.appendingPathComponent("spark.jsonl"))

        let quota = try await CodexUsageService.fetch(from: [root])

        #expect(quota.primary.usedPercent == 31)
        #expect(quota.primary.windowMinutes == 10_080)
        #expect(quota.secondary == nil)
        #expect(quota.planName == "prolite")
    }

    @Test("Finds canonical quota earlier in the same session file")
    func findsCanonicalQuotaEarlierInSameSessionFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T11:35:06.513Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 42,
                windowMinutes: 300,
                secondary: (17, 10_080)
            ),
            tokenCount(
                timestamp: "2026-07-17T11:35:24.973Z",
                limitID: "codex_bengalfox",
                limitName: "GPT-5.3-Codex-Spark",
                planType: nil,
                usedPercent: 0,
                windowMinutes: 10_080
            )
        ], to: root.appendingPathComponent("mixed.jsonl"))

        let quota = try await CodexUsageService.fetch(from: [root])

        #expect(quota.primary.usedPercent == 42)
        #expect(quota.primary.windowMinutes == 300)
        #expect(quota.secondary?.usedPercent == 17)
        #expect(quota.secondary?.windowMinutes == 10_080)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSONL(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func tokenCount(
        timestamp: String,
        limitID: String?,
        limitName: String?,
        planType: String?,
        usedPercent: Double,
        windowMinutes: Int,
        secondary: (usedPercent: Double, windowMinutes: Int)? = nil
    ) -> [String: Any] {
        var limits: [String: Any] = [
            "primary": window(usedPercent: usedPercent, windowMinutes: windowMinutes)
        ]
        if let limitID { limits["limit_id"] = limitID }
        if let limitName { limits["limit_name"] = limitName }
        if let planType { limits["plan_type"] = planType }
        if let secondary {
            limits["secondary"] = window(
                usedPercent: secondary.usedPercent,
                windowMinutes: secondary.windowMinutes
            )
        }
        return [
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "rate_limits": limits
            ]
        ]
    }

    private func window(usedPercent: Double, windowMinutes: Int) -> [String: Any] {
        [
            "used_percent": usedPercent,
            "window_minutes": windowMinutes,
            "resets_at": 1_784_780_221
        ]
    }
}
