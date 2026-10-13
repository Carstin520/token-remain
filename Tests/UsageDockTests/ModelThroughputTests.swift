import Foundation
import Testing
@testable import UsageDock

@Suite("Model throughput")
struct ModelThroughputTests {
    private func claude(_ lines: [String]) -> (ModelThroughputParser.ClaudeCarry, [String: ThroughputBucket]) {
        var carry = ModelThroughputParser.ClaudeCarry()
        var buckets: [String: ThroughputBucket] = [:]
        for line in lines {
            let data = Data(line.utf8)
            data.withUnsafeBytes { raw in
                ModelThroughputParser.consumeClaudeLine(
                    raw, 0..<raw.count, carry: &carry, agentID: "claude", into: &buckets
                )
            }
        }
        return (carry, buckets)
    }

    private func codex(_ lines: [String]) -> [String: ThroughputBucket] {
        var carry = ModelThroughputParser.CodexCarry()
        var buckets: [String: ThroughputBucket] = [:]
        for line in lines {
            let data = Data(line.utf8)
            data.withUnsafeBytes { raw in
                ModelThroughputParser.consumeCodexLine(
                    raw, 0..<raw.count, carry: &carry, agentID: "codex", into: &buckets
                )
            }
        }
        return buckets
    }

    private func key(_ timestamp: String, agent: String, model: String) -> String {
        let seconds = ModelThroughputParser.parseTimestamp(timestamp)!
        return ModelThroughputSnapshot.key(
            day: ModelThroughputParser.dayKey(Date(timeIntervalSince1970: seconds)),
            agentID: agent,
            modelID: model
        )
    }

    private func user(_ time: String) -> String {
        // Tool output may itself contain JSON-looking text; it must not be
        // mistaken for top-level fields.
        #"{"parentUuid":"x","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"{\"type\":\"assistant\",\"timestamp\":\"1999-01-01T00:00:00Z\"}"}]},"timestamp":"\#(time)"}"#
    }

    private func assistant(_ time: String, id: String, output: Int, model: String = "claude-opus-5-5") -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","model":"\#(model)","content":[{"type":"text","text":"a \"quoted\" {brace"}],"usage":{"input_tokens":3,"output_tokens":\#(output)}},"requestId":"r","timestamp":"\#(time)"}"#
    }

    @Test("Claude response time runs from the prompt to the last chunk of one message")
    func claudeMessageSpansChunks() {
        let (carry, buckets) = claude([
            user("2026-10-13T08:36:04.000Z"),
            assistant("2026-10-13T08:36:07.000Z", id: "msg_1", output: 120),
            assistant("2026-10-13T08:36:09.000Z", id: "msg_1", output: 250),
            user("2026-10-13T08:36:10.000Z"),
            assistant("2026-10-13T08:36:12.000Z", id: "msg_2", output: 200),
            user("2026-10-13T08:36:13.000Z")
        ])
        let bucket = buckets[key("2026-10-13T08:36:09.000Z", agent: "claude", model: "claude-opus-5-5")]
        #expect(bucket?.samples == 2)
        #expect(bucket?.outputTokens == 450)
        #expect(bucket?.seconds == 7)
        #expect(carry.pending == nil)
    }

    @Test("A trailing message stays pending until a later entry or an idle finalize")
    func claudeTrailingMessagePending() {
        var (carry, buckets) = claude([
            user("2026-10-13T08:00:00.000Z"),
            assistant("2026-10-13T08:00:05.000Z", id: "msg_1", output: 100)
        ])
        #expect(buckets.isEmpty)
        #expect(carry.pending?.outputTokens == 100)
        ModelThroughputParser.finalizeClaude(carry: &carry, agentID: "claude", into: &buckets)
        #expect(buckets.values.first?.samples == 1)
    }

    @Test("Synthetic, sub-second and idle-length responses are ignored")
    func claudeFiltersNoise() {
        let (_, buckets) = claude([
            user("2026-10-13T08:00:00.000Z"),
            assistant("2026-10-13T08:00:00.100Z", id: "fast", output: 50),
            user("2026-10-13T08:01:00.000Z"),
            assistant("2026-10-13T08:30:00.000Z", id: "idle", output: 50),
            user("2026-10-13T08:31:00.000Z"),
            assistant("2026-10-13T08:31:02.000Z", id: "syn", output: 50, model: "<synthetic>"),
            user("2026-10-13T08:32:00.000Z")
        ])
        #expect(buckets.isEmpty)
    }

    @Test("Codex usage records end at the last model item, not after tools ran")
    func codexUsageRecords() {
        let buckets = codex([
            #"{"timestamp":"2026-10-08T14:13:10.750Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-10-08T14:13:10.800Z","type":"turn_context","payload":{"turn_id":"t","model":"gpt-6-astra"}}"#,
            #"{"timestamp":"2026-10-08T14:13:20.750Z","type":"response_item","payload":{"type":"custom_tool_call","input":"{\"model\":\"nope\"}"}}"#,
            #"{"timestamp":"2026-10-08T14:13:40.000Z","type":"token_usage_record","payload":{"usage":{"input_tokens":5000,"output_tokens":300}}}"#,
            #"{"timestamp":"2026-10-08T14:13:40.001Z","type":"response_item","payload":{"type":"custom_tool_call_output","output":"ok"}}"#,
            #"{"timestamp":"2026-10-08T14:13:40.002Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":300},"total_token_usage":{"total_tokens":5300}}}}"#,
            #"{"timestamp":"2026-10-08T14:13:45.001Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#,
            #"{"timestamp":"2026-10-08T14:13:46.000Z","type":"token_usage_record","payload":{"usage":{"output_tokens":100}}}"#
        ])
        let bucket = buckets[key("2026-10-08T14:13:20.750Z", agent: "codex", model: "gpt-6-astra")]
        // 300 tokens over 10 s, then 100 tokens over 5 s; token_count repeats are skipped.
        #expect(bucket?.samples == 2)
        #expect(bucket?.outputTokens == 400)
        #expect(abs((bucket?.seconds ?? 0) - 15) < 0.01)
    }

    @Test("Older Codex logs use token_count and skip duplicate totals")
    func codexTokenCountFallback() {
        let buckets = codex([
            #"{"timestamp":"2026-09-01T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            #"{"timestamp":"2026-09-01T10:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#,
            #"{"timestamp":"2026-09-01T10:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant"}}"#,
            #"{"timestamp":"2026-09-01T10:00:04.100Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":200},"total_token_usage":{"total_tokens":900}}}}"#,
            #"{"timestamp":"2026-09-01T10:00:04.200Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":200},"total_token_usage":{"total_tokens":900}}}}"#
        ])
        let bucket = buckets.values.first
        #expect(buckets.count == 1)
        #expect(bucket?.samples == 1)
        #expect(bucket?.outputTokens == 200)
        #expect(bucket?.seconds == 4)
    }

    @Test("Fast timestamp parsing matches ISO8601DateFormatter")
    func parsesTimestamps() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for text in ["2026-10-13T08:36:04.592Z", "2024-02-29T23:59:59.999Z", "1999-12-31T00:00:00.000Z"] {
            let expected = formatter.date(from: text)!.timeIntervalSince1970
            #expect(abs(ModelThroughputParser.parseTimestamp(text)! - expected) < 0.0005)
        }
        #expect(ModelThroughputParser.parseTimestamp("2026-10-13T08:36:04Z") != nil)
        #expect(ModelThroughputParser.parseTimestamp("2026-10-13T16:36:04.000+08:00")
            == ModelThroughputParser.parseTimestamp("2026-10-13T08:36:04.000Z"))
        #expect(ModelThroughputParser.parseTimestamp("not a time") == nil)
    }

    @Test("Snapshot hides estimates without enough timed responses")
    func snapshotThresholds() {
        let day = Date(timeIntervalSince1970: 1_791_000_000)
        let key = ModelThroughputSnapshot.key(day: ModelThroughputParser.dayKey(day), agentID: "claude", modelID: "M")
        let thin = ModelThroughputSnapshot(buckets: [key: .init(outputTokens: 500, seconds: 10, samples: 2)])
        #expect(thin.tokensPerSecond(day: day, agentID: "claude", modelID: "m") == nil)
        let enough = ModelThroughputSnapshot(buckets: [key: .init(outputTokens: 500, seconds: 10, samples: 3)])
        #expect(enough.tokensPerSecond(day: day, agentID: "CLAUDE", modelID: "m") == 50)
    }

    @Test("Incremental scans read only appended lines and survive partial writes")
    func incrementalScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "throughput-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "projects/p", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let log = projects.appending(path: "session.jsonl")
        let cache = root.appending(path: "cache", directoryHint: .isDirectory)

        // Recent timestamps so the retention window keeps the file.
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func at(_ offset: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(offset - 600)) }

        let first = [
            user(at(0)), assistant(at(5), id: "m1", output: 100),
            user(at(10)), assistant(at(15), id: "m2", output: 100),
            user(at(20))
        ].joined(separator: "\n") + "\n" + String(assistant(at(25), id: "m3", output: 100).prefix(30))
        try Data(first.utf8).write(to: log)

        let service = ModelThroughputService(cacheDirectory: cache)
        let roots = [ModelThroughputService.Root(url: root.appending(path: "projects"), kind: .claude)]
        let once = await service.refresh(roots: roots, now: now)
        #expect(once.buckets.values.reduce(0) { $0 + $1.samples } == 2)

        // Finish the partial line and add more; nothing earlier is re-counted.
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        let rest = String(assistant(at(25), id: "m3", output: 100).dropFirst(30)) + "\n"
            + user(at(30)) + "\n"
        try handle.write(contentsOf: Data(rest.utf8))
        try handle.close()

        let twice = await service.refresh(roots: roots, now: now)
        #expect(twice.buckets.values.reduce(0) { $0 + $1.samples } == 3)

        // A fresh actor restores progress from the cache without rescanning.
        let restored = await ModelThroughputService(cacheDirectory: cache).cachedSnapshot()
        #expect(restored == twice)
    }

    @Test("Field scanner reads only top-level members")
    func fieldScannerTopLevelOnly() {
        let line = #"{"nested":{"type":"inner","timestamp":"x"},"text":"\"type\":\"fake\"","type":"real","n":42}"#
        let data = Data(line.utf8)
        data.withUnsafeBytes { raw in
            let fields = JSONFieldScanner.fields(raw, in: 0..<raw.count, keys: ["type", "n", "missing"])
            #expect(fields[0].flatMap { JSONFieldScanner.string(raw, $0) } == "real")
            #expect(fields[1].flatMap { JSONFieldScanner.int64(raw, $0) } == 42)
            #expect(fields[2] == nil)
        }
    }
}

@Suite("Quota card model speed")
struct ModelSpeedSummaryTests {
    private let calendar = Calendar.current

    private func day(_ offset: Int, now: Date, models: [(String, Int64)]) -> DailyUsageHistory.Day {
        let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        return .init(date: date, agents: [.init(
            id: "codex",
            tokens: models.reduce(0) { $0 + $1.1 },
            cost: 0,
            models: models.map { .init(id: $0.0, inputTokens: $0.1, outputTokens: 0, cacheTokens: 0, cost: 0) }
        )])
    }

    private func bucket(_ offset: Int, now: Date, model: String, output: Int64, seconds: Double, samples: Int) -> (String, ThroughputBucket) {
        let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        return (
            ModelThroughputSnapshot.key(day: ModelThroughputParser.dayKey(date), agentID: "codex", modelID: model),
            ThroughputBucket(outputTokens: output, seconds: seconds, samples: samples)
        )
    }

    @Test("Today's most-used model wins and its speed averages the last seven days")
    func todaysTopModel() {
        let now = Date()
        let history = DailyUsageHistory(days: [
            day(-3, now: now, models: [("gpt-6.1-sol", 900)]),
            day(0, now: now, models: [("gpt-6-astra", 500), ("gpt-6.1-sol", 100)])
        ], capturedAt: now)
        let throughput = ModelThroughputSnapshot(buckets: Dictionary(uniqueKeysWithValues: [
            bucket(0, now: now, model: "gpt-6-astra", output: 100, seconds: 10, samples: 1),
            bucket(-2, now: now, model: "gpt-6-astra", output: 500, seconds: 10, samples: 2),
            bucket(-9, now: now, model: "gpt-6-astra", output: 9_000, seconds: 10, samples: 9),
            bucket(0, now: now, model: "gpt-6.1-sol", output: 900, seconds: 10, samples: 9)
        ]))
        let speed = ModelSpeedSummary.make(history: history, throughput: throughput, agentID: "codex", now: now)
        #expect(speed?.modelID == "gpt-6-astra")
        // Day -9 is outside the window: (100 + 500) / 20 s.
        #expect(speed?.tokensPerSecond == 30)
    }

    @Test("Without usage today the last seven days decide the model")
    func fallsBackToWeek() {
        let now = Date()
        let history = DailyUsageHistory(days: [
            day(-1, now: now, models: [("gpt-6.1-sol", 900), ("gpt-6-astra", 100)])
        ], capturedAt: now)
        let throughput = ModelThroughputSnapshot(buckets: Dictionary(uniqueKeysWithValues: [
            bucket(-1, now: now, model: "gpt-6.1-sol", output: 220, seconds: 10, samples: 5)
        ]))
        let speed = ModelSpeedSummary.make(history: history, throughput: throughput, agentID: "codex", now: now)
        #expect(speed?.modelID == "gpt-6.1-sol")
        #expect(speed?.tokensPerSecond == 22)
    }

    @Test("A top model without a reliable estimate shows nothing, not another model")
    func noSubstitution() {
        let now = Date()
        let history = DailyUsageHistory(days: [
            day(0, now: now, models: [("gpt-6-astra", 900), ("gpt-6.1-sol", 100)])
        ], capturedAt: now)
        let throughput = ModelThroughputSnapshot(buckets: Dictionary(uniqueKeysWithValues: [
            bucket(0, now: now, model: "gpt-6-astra", output: 50, seconds: 2, samples: 1),
            bucket(0, now: now, model: "gpt-6.1-sol", output: 900, seconds: 10, samples: 9)
        ]))
        #expect(ModelSpeedSummary.make(history: history, throughput: throughput, agentID: "codex", now: now) == nil)
        #expect(ModelSpeedSummary.make(history: history, throughput: throughput, agentID: "cursor", now: now) == nil)
    }
}

/// Advances a fixed step every time the service reads the clock, so deadline
/// behavior is deterministic instead of depending on machine speed.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        current = start
        self.step = step
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(step)
        return current
    }
}

@Suite("Model throughput budget")
struct ModelThroughputBudgetTests {
    private func line(_ type: String, _ time: String, id: String = "") -> String {
        type == "user"
            ? #"{"type":"user","message":{"content":"x"},"timestamp":"\#(time)"}"#
            : #"{"type":"assistant","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"output_tokens":100}},"timestamp":"\#(time)"}"#
    }

    private func makeLog(responses: Int, in root: URL, now: Date) throws {
        let projects = root.appending(path: "projects/p", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = now.addingTimeInterval(-3_600)
        var text = ""
        for index in 0..<responses {
            let start = base.addingTimeInterval(Double(index) * 2)
            text += line("user", iso.string(from: start)) + "\n"
            text += line("assistant", iso.string(from: start.addingTimeInterval(1)), id: "m\(index)") + "\n"
        }
        text += line("user", iso.string(from: base.addingTimeInterval(Double(responses) * 2))) + "\n"
        try Data(text.utf8).write(to: projects.appending(path: "session.jsonl"))
    }

    private func samples(_ snapshot: ModelThroughputSnapshot) -> Int {
        snapshot.buckets.values.reduce(0) { $0 + $1.samples }
    }

    @Test("A pass stops at the deadline mid-file and later passes finish without double counting")
    func deadlineStopsMidFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "budget-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try makeLog(responses: 2_000, in: root, now: now)
        let roots = [ModelThroughputService.Root(url: root.appending(path: "projects"), kind: .claude)]

        // Every clock read costs one second against a 10-second budget, and a
        // 4 KB chunk holds only a few dozen responses: the file cannot finish
        // in one pass, however fast the machine is.
        let clock = SteppingClock(start: now, step: 1)
        let service = ModelThroughputService(
            cacheDirectory: root.appending(path: "cache"),
            timeBudget: 10,
            chunkBytes: 4_096,
            clock: { clock.now() }
        )
        let first = await service.refresh(roots: roots, now: now)
        #expect(samples(first) > 0)
        #expect(samples(first) < 2_000)

        var latest = first
        for _ in 0..<500 where samples(latest) < 2_000 {
            latest = await service.refresh(roots: roots, now: now)
        }
        #expect(samples(latest) == 2_000)

        let reference = ModelThroughputService(cacheDirectory: root.appending(path: "reference"))
        #expect(await reference.refresh(roots: roots, now: now) == latest)
    }

    @Test("A pass cut short during discovery keeps earlier progress")
    func truncatedDiscoveryKeepsState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "budget-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try makeLog(responses: 10, in: root, now: now)
        let roots = [ModelThroughputService.Root(url: root.appending(path: "projects"), kind: .claude)]
        let cache = root.appending(path: "cache")

        let complete = await ModelThroughputService(cacheDirectory: cache).refresh(roots: roots, now: now)
        #expect(samples(complete) == 10)

        // A zero budget ends the pass before discovery finds anything; the
        // cached state must survive rather than be pruned as "deleted".
        let starved = ModelThroughputService(cacheDirectory: cache, timeBudget: 0)
        #expect(await starved.refresh(roots: roots, now: now) == complete)
        #expect(await ModelThroughputService(cacheDirectory: cache).cachedSnapshot() == complete)
    }
}

@Suite("Model throughput cache writes")
struct ModelThroughputCacheWriteTests {
    @Test("A pass with no new log bytes leaves the cache file untouched")
    func unchangedPassSkipsWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "writes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "projects/p", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date().addingTimeInterval(-600)
        let lines = [
            #"{"type":"user","timestamp":"\#(iso.string(from: start))"}"#,
            #"{"type":"assistant","message":{"id":"m","model":"x","usage":{"output_tokens":50}},"timestamp":"\#(iso.string(from: start.addingTimeInterval(2)))"}"#,
            #"{"type":"user","timestamp":"\#(iso.string(from: start.addingTimeInterval(3)))"}"#
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: projects.appending(path: "s.jsonl"))
        let cacheDirectory = root.appending(path: "cache")
        let cacheFile = cacheDirectory.appending(path: "model-throughput-v1.json")
        let roots = [ModelThroughputService.Root(url: root.appending(path: "projects"), kind: .claude)]
        let service = ModelThroughputService(cacheDirectory: cacheDirectory)

        _ = await service.refresh(roots: roots)
        let written = try #require(try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date)
        // Backdate the cache so any rewrite would visibly move its timestamp.
        let backdated = written.addingTimeInterval(-3_600)
        try FileManager.default.setAttributes([.modificationDate: backdated], ofItemAtPath: cacheFile.path)

        _ = await service.refresh(roots: roots)
        let after = try #require(try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date)
        #expect(abs(after.timeIntervalSince(backdated)) < 1)
    }
}
