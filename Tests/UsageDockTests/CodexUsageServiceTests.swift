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
        // 单窗模型快照只生成一条 scoped,周窗归入 `_weekly` 后缀。
        let spark = try #require(quota.uniqueScopedWindows.first)
        #expect(quota.uniqueScopedWindows.count == 1)
        #expect(spark.scopeID == "codex_bengalfox_weekly")
        #expect(spark.displayName == "GPT-5.3-Codex-Spark")
        #expect(spark.window.usedPercent == 0)
        #expect(spark.window.windowMinutes == 10_080)
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
        #expect(quota.uniqueScopedWindows.first?.displayName == "GPT-5.3-Codex-Spark")
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
        // 旧会话的 mtime 介于两个事件时间之间,处在早停宽容窗内,
        // 仍会被解析;无论走早停还是全量,结果都必须取最新快照。
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
        #expect(quota.uniqueScopedWindows.first?.displayName == "GPT-5.3-Codex-Spark")
    }

    @Test("Newest model-specific weekly snapshot wins without replacing the account quota")
    func newestModelSpecificSnapshotWins() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T11:35:06.513Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 31,
                windowMinutes: 300,
                secondary: (22, 10_080)
            ),
            tokenCount(
                timestamp: "2026-07-17T11:35:12.000Z",
                limitID: "codex_bengalfox",
                limitName: "GPT-5.3-Codex-Spark",
                planType: nil,
                usedPercent: 9,
                windowMinutes: 300,
                secondary: (40, 10_080)
            ),
            tokenCount(
                timestamp: "2026-07-17T11:35:24.973Z",
                limitID: "codex_bengalfox",
                limitName: "GPT-5.3-Codex-Spark",
                planType: nil,
                usedPercent: 10,
                windowMinutes: 300,
                secondary: (44, 10_080)
            )
        ], to: root.appendingPathComponent("mixed.jsonl"))

        let quota = try await CodexUsageService.fetch(from: [root])
        let scoped = quota.uniqueScopedWindows

        #expect(quota.primary.usedPercent == 31)
        #expect(quota.secondary?.usedPercent == 22)
        // 同一模型的两个窗都取最新快照的读数,成对存活、短窗在前。
        #expect(scoped.map(\.scopeID) == ["codex_bengalfox_session", "codex_bengalfox_weekly"])
        #expect(scoped.first?.window.usedPercent == 10)
        #expect(scoped.first?.window.windowMinutes == 300)
        #expect(scoped.last?.window.usedPercent == 44)
        #expect(scoped.last?.window.windowMinutes == 10_080)
    }

    @Test("A model pool's 5h and 7d windows both survive as a scoped pair")
    func modelPoolWindowsSurviveAsPair() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T11:35:06.513Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 31,
                windowMinutes: 300,
                secondary: (22, 10_080)
            ),
            // 模型池 5h 已逼近打满、7d 才用了 44%:两个维度都必须可见,
            // 否则 5h 耗尽时用户看不到任何提示(审计红项)。
            tokenCount(
                timestamp: "2026-07-17T11:35:24.973Z",
                limitID: "codex_bengalfox",
                limitName: "GPT-5.3-Codex-Spark",
                planType: nil,
                usedPercent: 95,
                windowMinutes: 300,
                secondary: (44, 10_080)
            )
        ], to: root.appendingPathComponent("mixed.jsonl"))

        let quota = try await CodexUsageService.fetch(from: [root])
        let scoped = quota.uniqueScopedWindows

        #expect(scoped.map(\.scopeID) == ["codex_bengalfox_session", "codex_bengalfox_weekly"])
        #expect(scoped.map(\.displayName) == ["GPT-5.3-Codex-Spark", "GPT-5.3-Codex-Spark"])
        #expect(scoped.first?.window.usedPercent == 95)
        #expect(scoped.first?.window.windowMinutes == 300)
        #expect(scoped.last?.window.usedPercent == 44)
        #expect(scoped.last?.window.windowMinutes == 10_080)
        // Spark 显示开关依赖 isCodexSpark,两条后缀窗口都必须命中。
        #expect(scoped.allSatisfy { $0.isCodexSpark })
        // 账户级主卡不受模型池影响。
        #expect(quota.primary.usedPercent == 31)
        #expect(quota.secondary?.usedPercent == 22)
    }

    @Test("A snapshot without resets_at is kept instead of being dropped")
    func missingResetsAtDoesNotDropSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeJSONL([
            // 账户级快照缺 resets_at:QuotaWindow.resetsAt 本是 Optional,
            // 解析器不应因此丢掉整条快照。
            tokenCount(
                timestamp: "2026-07-17T11:35:06.513Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 31,
                windowMinutes: 300,
                secondary: (22, 10_080),
                resetsAt: nil
            ),
            tokenCount(
                timestamp: "2026-07-17T11:35:24.973Z",
                limitID: "codex_bengalfox",
                limitName: "GPT-5.3-Codex-Spark",
                planType: nil,
                usedPercent: 9,
                windowMinutes: 300,
                secondary: (40, 10_080),
                resetsAt: nil
            )
        ], to: root.appendingPathComponent("no-resets.jsonl"))

        let quota = try await CodexUsageService.fetch(from: [root])

        #expect(quota.primary.usedPercent == 31)
        #expect(quota.primary.resetsAt == nil)
        #expect(quota.secondary?.usedPercent == 22)
        #expect(
            quota.uniqueScopedWindows.map(\.scopeID)
                == ["codex_bengalfox_session", "codex_bengalfox_weekly"]
        )
    }

    @Test("isCodexSpark still matches the suffixed model-pool scope IDs")
    func sparkDetectionSurvivesScopeSuffixes() {
        let window = QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil)
        func scoped(_ scopeID: String, _ displayName: String) -> ScopedQuotaWindow {
            ScopedQuotaWindow(scopeID: scopeID, displayName: displayName, window: window)
        }

        // 精确 ID、带后缀的成对 ID 与 displayName 三条路径都要命中。
        #expect(scoped("codex_bengalfox", "GPT-5.3-Codex-Spark").isCodexSpark)
        #expect(scoped("codex_bengalfox_session", "GPT-5.3-Codex-Spark").isCodexSpark)
        #expect(scoped("codex_bengalfox_weekly", "GPT-5.3-Codex-Spark").isCodexSpark)
        #expect(scoped("codex_bengalfox_weekly", "Other").isCodexSpark)
        #expect(!scoped("fable", "Fable").isCodexSpark)
        #expect(!scoped("codex_other_model", "GPT-5.3-Codex-Mini").isCodexSpark)
    }

    @Test("Long limit_ids with a shared 24-char prefix keep distinct, stable scope IDs")
    func longLimitIDsDoNotCollideAfterTruncation() {
        let alpha = "codex_bengalfox_pro_extended_alpha"
        let beta = "codex_bengalfox_pro_extended_beta"
        #expect(String(alpha.prefix(24)) == String(beta.prefix(24)))

        let alphaBase = CodexUsageService.wireScopeBase(for: alpha)
        let betaBase = CodexUsageService.wireScopeBase(for: beta)

        // 旧实现截前 24 字符会碰撞;新基底必须可区分。
        #expect(alphaBase != betaBase)
        // 确定性:FNV-1a 自实现,跨调用/跨进程稳定到具体字面值。
        #expect(alphaBase == "codex_bengalfox_071fde96")
        #expect(betaBase == "codex_bengalfox_563343ac")
        #expect(alphaBase == CodexUsageService.wireScopeBase(for: alpha))
        // 基底 ≤24,拼上最长的 `_session` 后缀仍在 32 字符 scopeID 上限内。
        #expect(alphaBase.count == 24)
        #expect((alphaBase + "_session").count <= 32)
        // 15 字符前缀保住 hasPrefix("codex_bengalfox") 的 Spark 判定。
        #expect(alphaBase.hasPrefix("codex_bengalfox"))
        // ≤24 字节的 id 原样使用,现有 scopeID 不因此改变。
        #expect(CodexUsageService.wireScopeBase(for: "codex_bengalfox") == "codex_bengalfox")
    }

    @Test("Two long-id model pools stay separate scoped windows end to end")
    func longIDModelPoolsSurviveAsSeparatePools() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T11:35:06.513Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 31,
                windowMinutes: 300,
                secondary: (22, 10_080)
            ),
            tokenCount(
                timestamp: "2026-07-17T11:35:12.000Z",
                limitID: "codex_bengalfox_pro_extended_alpha",
                limitName: "GPT-5.3-Codex-Spark-Alpha",
                planType: nil,
                usedPercent: 9,
                windowMinutes: 300,
                secondary: (40, 10_080)
            ),
            tokenCount(
                timestamp: "2026-07-17T11:35:24.973Z",
                limitID: "codex_bengalfox_pro_extended_beta",
                limitName: "GPT-5.3-Codex-Spark-Beta",
                planType: nil,
                usedPercent: 77,
                windowMinutes: 300,
                secondary: (58, 10_080)
            )
        ], to: root.appendingPathComponent("long-ids.jsonl"))

        let quota = try await CodexUsageService.fetch(from: [root])
        let scoped = quota.uniqueScopedWindows

        // 前 24 字符相同的两个模型池不允许被折叠成一个:各自的
        // session/weekly 成对存活,读数互不覆盖。
        #expect(scoped.count == 4)
        #expect(Set(scoped.map(\.scopeID)).count == 4)
        #expect(scoped.map(\.scopeID) == [
            "codex_bengalfox_071fde96_session",
            "codex_bengalfox_071fde96_weekly",
            "codex_bengalfox_563343ac_session",
            "codex_bengalfox_563343ac_weekly"
        ])
        #expect(scoped.allSatisfy { $0.scopeID.count <= 32 })
        #expect(scoped.first { $0.scopeID.hasSuffix("071fde96_session") }?.window.usedPercent == 9)
        #expect(scoped.first { $0.scopeID.hasSuffix("563343ac_session") }?.window.usedPercent == 77)
    }

    @Test("A rewritten session file (new mtime) invalidates the parse cache")
    func mtimeChangeInvalidatesCache() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("session.jsonl")
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T10:00:00.000Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 50,
                windowMinutes: 300
            )
        ], to: file)
        let first = try await CodexUsageService.fetch(from: [root])
        #expect(first.primary.usedPercent == 50)

        // 追加新事件后 mtime 变化,缓存必须失效并读到新值。
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T12:00:00.000Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 70,
                windowMinutes: 300
            )
        ], to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: file.path
        )
        let second = try await CodexUsageService.fetch(from: [root])
        #expect(second.primary.usedPercent == 70)
    }

    @Test("An unchanged mtime serves the cached parse without re-reading the file")
    func unchangedMtimeServesCachedParse() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("session.jsonl")
        let pinnedMtime = ISO8601DateFormatter().date(from: "2026-07-17T10:05:00Z")!
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T10:00:00.000Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 50,
                windowMinutes: 300
            )
        ], to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedMtime],
            ofItemAtPath: file.path
        )
        let first = try await CodexUsageService.fetch(from: [root])
        #expect(first.primary.usedPercent == 50)

        // 改写内容但把 mtime 恢复原值:约定按 mtime 信任缓存,此时应
        // 返回旧解析结果——这正是"未变文件零 I/O"的可观测证据。
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T10:01:00.000Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 90,
                windowMinutes: 300
            )
        ], to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedMtime],
            ofItemAtPath: file.path
        )
        let second = try await CodexUsageService.fetch(from: [root])
        #expect(second.primary.usedPercent == 50)
    }

    @Test("A new session survives an mtime rollback beyond the early-stop window")
    func newSessionSurvivesLargeClockRollback() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let established = root.appendingPathComponent("established.jsonl")
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T11:00:00.000Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 40,
                windowMinutes: 300
            )
        ], to: established)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-07-17T11:05:00Z")!],
            ofItemAtPath: established.path
        )
        let first = try await CodexUsageService.fetch(from: [root])
        #expect(first.primary.usedPercent == 40)

        // The file is newly created, but its filesystem clock is more than a
        // day behind the established canonical event. A pure mtime early stop
        // would never parse it even though its authenticated event is newer.
        let rolledBack = root.appendingPathComponent("rolled-back.jsonl")
        try writeJSONL([
            tokenCount(
                timestamp: "2026-07-17T12:00:00.000Z",
                limitID: "codex",
                limitName: nil,
                planType: "prolite",
                usedPercent: 65,
                windowMinutes: 300
            )
        ], to: rolledBack)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-07-15T11:00:00Z")!],
            ofItemAtPath: rolledBack.path
        )

        let second = try await CodexUsageService.fetch(from: [root])
        #expect(second.primary.usedPercent == 65)
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
        secondary: (usedPercent: Double, windowMinutes: Int)? = nil,
        resetsAt: Double? = 1_784_780_221
    ) -> [String: Any] {
        var limits: [String: Any] = [
            "primary": window(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt
            )
        ]
        if let limitID { limits["limit_id"] = limitID }
        if let limitName { limits["limit_name"] = limitName }
        if let planType { limits["plan_type"] = planType }
        if let secondary {
            limits["secondary"] = window(
                usedPercent: secondary.usedPercent,
                windowMinutes: secondary.windowMinutes,
                resetsAt: resetsAt
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

    private func window(
        usedPercent: Double,
        windowMinutes: Int,
        resetsAt: Double? = 1_784_780_221
    ) -> [String: Any] {
        var value: [String: Any] = [
            "used_percent": usedPercent,
            "window_minutes": windowMinutes
        ]
        if let resetsAt { value["resets_at"] = resetsAt }
        return value
    }
}
