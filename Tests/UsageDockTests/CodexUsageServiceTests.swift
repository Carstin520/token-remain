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

    @Test("Newest canonical snapshot wins; older session files cannot outrank it")
    func newestCanonicalWinsAcrossSessionFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFile = root.appendingPathComponent("old.jsonl")
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T10:00:00.000Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 80,
                windowMinutes: 300
            )
        ], to: oldFile)
        // 旧会话的 mtime 介于两个事件时间之间:新文件解析出的快照一旦
        // 晚于它,扫描应当在这里早停,而结果与全量扫描一致。
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-07-17T10:30:00Z")!],
            ofItemAtPath: oldFile.path
        )
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T11:00:00.000Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 55,
                windowMinutes: 300
            )
        ], to: root.appendingPathComponent("new.jsonl"))

        let quota = try await CodexUsageService.fetch(from: [root])

        #expect(quota.primary.usedPercent == 55)
    }

    @Test("Legacy snapshot still surfaces when no canonical limit exists anywhere")
    func legacyFallbackSurvivesEarlyStop() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyFile = root.appendingPathComponent("legacy.jsonl")
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T09:00:00.000Z",
                limitID: nil,
                limitName: nil,
                planType: nil,
                usedPercent: 63,
                windowMinutes: 300
            )
        ], to: legacyFile)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-07-17T09:05:00Z")!],
            ofItemAtPath: legacyFile.path
        )
        // 更新的会话只有模型专属限额:既非账户级也非 legacy,不允许
        // 提前终止扫描,否则老文件里的 legacy 快照会被漏掉。
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

        #expect(quota.primary.usedPercent == 63)
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
