import CryptoKit
import Foundation

/// Output tokens and wall-clock seconds summed over qualifying model responses.
struct ThroughputBucket: Codable, Equatable, Sendable {
    var outputTokens: Int64 = 0
    var seconds: Double = 0
    var samples: Int = 0

    mutating func merge(_ other: ThroughputBucket) {
        outputTokens += other.outputTokens
        seconds += other.seconds
        samples += other.samples
    }
}

/// Per-day, per-agent, per-model end-to-end output speed estimated from local
/// session logs. The rate is token-weighted (Σ output ÷ Σ seconds), so a
/// handful of tiny replies dominated by first-token latency cannot swing it.
struct ModelThroughputSnapshot: Equatable, Sendable {
    /// Below this, the estimate is too noisy to show next to measured usage.
    static let minimumSamples = 3
    static let minimumSeconds: Double = 5

    let buckets: [String: ThroughputBucket]

    static let empty = ModelThroughputSnapshot(buckets: [:])

    func tokensPerSecond(day: Date, agentID: String, modelID: String) -> Double? {
        let key = Self.key(day: ModelThroughputParser.dayKey(day), agentID: agentID, modelID: modelID)
        guard let bucket = buckets[key],
              bucket.samples >= Self.minimumSamples,
              bucket.seconds >= Self.minimumSeconds,
              bucket.outputTokens > 0 else { return nil }
        return Double(bucket.outputTokens) / bucket.seconds
    }

    static func key(day: String, agentID: String, modelID: String) -> String {
        "\(day)|\(agentID.lowercased())|\(modelID.lowercased())"
    }

    /// Token-weighted speed over several days; the same noise floor applies
    /// to the combined total.
    func tokensPerSecond(days: [Date], agentID: String, modelID: String) -> Double? {
        var total = ThroughputBucket()
        for day in Set(days.map { ModelThroughputParser.dayKey($0) }) {
            if let bucket = buckets[Self.key(day: day, agentID: agentID, modelID: modelID)] {
                total.merge(bucket)
            }
        }
        guard total.samples >= Self.minimumSamples,
              total.seconds >= Self.minimumSeconds,
              total.outputTokens > 0 else { return nil }
        return Double(total.outputTokens) / total.seconds
    }
}

/// The speed shown on a provider's quota card: its most-used model and that
/// model's recent average.
struct ModelSpeedSummary: Equatable, Sendable {
    static let windowDays = 7

    let modelID: String
    let tokensPerSecond: Double

    var displayName: String {
        modelID.hasPrefix("claude-") ? String(modelID.dropFirst("claude-".count)) : modelID
    }

    /// "Most used" ranks today's models by tokens, falling back to the last
    /// `windowDays` when today has none. Speed averages the same window so one
    /// short day cannot swing it. When the top model has no reliable estimate
    /// the result is nil; another model is never shown in its place.
    static func make(
        history: DailyUsageHistory?,
        throughput: ModelThroughputSnapshot,
        agentID: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ModelSpeedSummary? {
        guard let history, !throughput.buckets.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let earliest = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) else {
            return nil
        }
        let agent = agentID.lowercased()
        let days = history.days.filter { $0.date >= earliest && $0.date <= now }

        func totals(_ days: [DailyUsageHistory.Day]) -> [String: Int64] {
            var totals: [String: Int64] = [:]
            for day in days {
                for entry in day.agents where entry.id.lowercased() == agent {
                    for model in entry.models where model.id != "other" {
                        totals[model.id, default: 0] += model.totalTokens
                    }
                }
            }
            return totals
        }

        var ranking = totals(days.filter { calendar.isDate($0.date, inSameDayAs: today) })
        if ranking.isEmpty { ranking = totals(days) }
        guard let top = ranking.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }), top.value > 0 else { return nil }

        let windowDates = (0..<windowDays).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        guard let speed = throughput.tokensPerSecond(days: windowDates, agentID: agent, modelID: top.key) else {
            return nil
        }
        return ModelSpeedSummary(modelID: top.key, tokensPerSecond: speed)
    }
}

/// Incremental reader for Claude Code and Codex session logs.
///
/// Resource contract: each log is append-only, so a scan reads only the bytes
/// written since the previous scan (tracked per file) and runs after the
/// existing ccusage refresh instead of on a timer of its own. The first scan of
/// a large backlog is spread across refreshes by a byte and time budget, with
/// progress persisted. Lines are walked by a byte scanner that extracts only
/// timestamps, entry types, message ids, model names and token counters;
/// prompts, code and tool output are never decoded, stored or sent anywhere.
actor ModelThroughputService {
    enum LogKind: String, Codable, Sendable {
        case claude
        case codex
    }

    struct Root: Sendable, Equatable {
        let url: URL
        let kind: LogKind
    }

    static let shared = ModelThroughputService()
    static let retentionDays = 31
    static let maximumFiles = 20_000
    static let bytesPerRefresh = 256 * 1024 * 1024
    static let secondsPerRefresh: TimeInterval = 8
    static let chunkBytes = 4 * 1024 * 1024
    /// A trailing response is finalized once its session has been quiet this
    /// long; until then another chunk of the same message may still arrive.
    static let idleFinalizeAfter: TimeInterval = 120
    private static let cacheSchemaVersion = 1

    private struct FileState: Codable {
        var kind: LogKind
        var offset: Int64
        var modifiedAt: Date
        var claude: ModelThroughputParser.ClaudeCarry?
        var codex: ModelThroughputParser.CodexCarry?
        var buckets: [String: ThroughputBucket]
    }

    private struct StoredState: Codable {
        var schemaVersion: Int
        var files: [String: FileState]
    }

    private let fileManager: FileManager
    private let cacheURL: URL
    private let byteBudget: Int
    private let timeBudget: TimeInterval
    private let chunkBytes: Int
    /// Injected so tests can drive the deadline deterministically.
    private let clock: @Sendable () -> Date
    private var files: [String: FileState] = [:]
    private var didLoadCache = false

    init(
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default,
        byteBudget: Int = ModelThroughputService.bytesPerRefresh,
        timeBudget: TimeInterval = ModelThroughputService.secondsPerRefresh,
        chunkBytes: Int = ModelThroughputService.chunkBytes,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.byteBudget = max(1, byteBudget)
        self.timeBudget = timeBudget
        self.chunkBytes = max(1, chunkBytes)
        self.clock = clock
        let directory = cacheDirectory ?? fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appending(path: "com.jamesli.usagedock", directoryHint: .isDirectory)
        cacheURL = directory.appending(path: "model-throughput-v1.json")
    }

    /// The last persisted estimate, without touching any log file.
    func cachedSnapshot() -> ModelThroughputSnapshot {
        loadCacheIfNeeded()
        return aggregate()
    }

    func refresh(roots: [Root], now: Date = .now) -> ModelThroughputSnapshot {
        loadCacheIfNeeded()
        let earliest = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        // The deadline covers discovery as well as reading, and is checked
        // between chunks, so one large log cannot hold a pass past it; the
        // overshoot is at most one chunk's parse.
        let deadline = clock().addingTimeInterval(timeBudget)
        let discovery = discoverFiles(roots: roots, modifiedAfter: earliest, deadline: deadline)
        var remainingBytes = byteBudget

        // Newest first, so a budget-limited backlog fills today's numbers before
        // older days.
        for file in discovery.files.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            let key = Self.fileKey(file.url)
            guard !Task.isCancelled, clock() < deadline else { break }
            var state = files[key] ?? FileState(
                kind: file.kind,
                offset: 0,
                modifiedAt: .distantPast,
                buckets: [:]
            )
            if state.kind != file.kind || file.size < state.offset {
                // A rewritten or reclassified file starts over; its old
                // contribution would otherwise be counted twice.
                state = FileState(kind: file.kind, offset: 0, modifiedAt: .distantPast, buckets: [:])
            }
            if file.size > state.offset, remainingBytes > 0 {
                let consumed = read(file: file, state: &state, maximumBytes: remainingBytes, deadline: deadline)
                remainingBytes -= consumed
            }
            if state.offset >= file.size,
               now.timeIntervalSince(file.modifiedAt) >= Self.idleFinalizeAfter,
               state.kind == .claude,
               var carry = state.claude {
                ModelThroughputParser.finalizeClaude(carry: &carry, agentID: "claude", into: &state.buckets)
                state.claude = carry
            }
            state.modifiedAt = file.modifiedAt
            Self.prune(&state.buckets, earliest: earliest)
            files[key] = state
        }
        // Forget a file only when a complete discovery no longer finds it
        // (deleted or aged out). A pass cut short by the deadline, the file
        // cap or cancellation keeps every earlier state; dropping them would
        // re-read those logs from byte 0 and double the work next time.
        if discovery.isComplete, !Task.isCancelled {
            let present = Set(discovery.files.map { Self.fileKey($0.url) })
            files = files.filter { present.contains($0.key) }
        }
        save()
        return aggregate()
    }

    // MARK: - Files

    private struct DiscoveredFile {
        let url: URL
        let kind: LogKind
        let size: Int64
        let modifiedAt: Date
    }

    private func discoverFiles(
        roots: [Root],
        modifiedAfter earliest: Date,
        deadline: Date
    ) -> (files: [DiscoveredFile], isComplete: Bool) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        var seen = Set<String>()
        var result: [DiscoveredFile] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root.url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard result.count < Self.maximumFiles,
                      !Task.isCancelled,
                      clock() < deadline else { return (result, false) }
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= earliest,
                      let size = values.fileSize else { continue }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                result.append(DiscoveredFile(url: url, kind: root.kind, size: Int64(size), modifiedAt: modified))
            }
        }
        return (result, true)
    }

    /// Reads whole lines from `state.offset`, leaving a trailing partial line
    /// for the next scan. Returns the number of bytes read.
    private func read(
        file: DiscoveredFile,
        state: inout FileState,
        maximumBytes: Int,
        deadline: Date
    ) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return 0 }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(state.offset))
        } catch {
            return 0
        }
        var consumed = 0
        var pending = Data()
        while consumed < maximumBytes, !Task.isCancelled, clock() < deadline {
            let want = min(chunkBytes, maximumBytes - consumed)
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            consumed += chunk.count
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else {
                // A single line larger than the chunk keeps accumulating; give
                // up on pathological lines rather than buffering without bound.
                if pending.count > max(chunkBytes, Self.chunkBytes) * 4 {
                    state.offset += Int64(pending.count)
                    pending.removeAll(keepingCapacity: false)
                }
                continue
            }
            let complete = pending[pending.startIndex...lastNewline]
            process(lines: complete, state: &state)
            state.offset += Int64(complete.count)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        return consumed
    }

    private func process(lines data: Data, state: inout FileState) {
        data.withUnsafeBytes { raw in
            var start = 0
            let count = raw.count
            while start < count {
                var end = start
                while end < count, raw[end] != 0x0A { end += 1 }
                if end > start {
                    switch state.kind {
                    case .claude:
                        var carry = state.claude ?? .init()
                        ModelThroughputParser.consumeClaudeLine(
                            raw, start..<end, carry: &carry, agentID: "claude", into: &state.buckets
                        )
                        state.claude = carry
                    case .codex:
                        var carry = state.codex ?? .init()
                        ModelThroughputParser.consumeCodexLine(
                            raw, start..<end, carry: &carry, agentID: "codex", into: &state.buckets
                        )
                        state.codex = carry
                    }
                }
                start = end + 1
            }
        }
    }

    // MARK: - Aggregation & cache

    private func aggregate() -> ModelThroughputSnapshot {
        var buckets: [String: ThroughputBucket] = [:]
        for state in files.values {
            for (key, bucket) in state.buckets {
                buckets[key, default: .init()].merge(bucket)
            }
        }
        return ModelThroughputSnapshot(buckets: buckets)
    }

    private static func prune(_ buckets: inout [String: ThroughputBucket], earliest: Date) {
        let cutoff = ModelThroughputParser.dayKey(earliest)
        buckets = buckets.filter { key, _ in
            key.split(separator: "|", maxSplits: 1).first.map { String($0) >= cutoff } ?? false
        }
    }

    /// Log paths name the user's projects; only a digest is persisted.
    private static func fileKey(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode(StoredState.self, from: data),
              stored.schemaVersion == Self.cacheSchemaVersion else { return }
        files = stored.files
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(
                StoredState(schemaVersion: Self.cacheSchemaVersion, files: files)
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // The estimate is optional; a failed save only costs a rescan.
        }
    }

    // MARK: - Roots

    static func defaultRoots(
        claudeConfigDirectories: [URL],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Root] {
        var roots = claudeConfigDirectories.map {
            Root(url: $0.appending(path: "projects", directoryHint: .isDirectory), kind: .claude)
        }
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".codex", directoryHint: .isDirectory)
        roots.append(Root(url: codexHome.appending(path: "sessions", directoryHint: .isDirectory), kind: .codex))
        return roots
    }
}

/// Pure, line-at-a-time throughput extraction. Split from the actor so tests
/// can feed fixture lines without touching the filesystem.
enum ModelThroughputParser {
    /// A response shorter than this is mostly connection setup; longer than
    /// the upper bound usually means the session sat idle mid-turn.
    static let durationRange: ClosedRange<Double> = 0.25...600
    /// Rates above this come from clock skew or replayed entries, not a model.
    static let maximumTokensPerSecond: Double = 5_000

    struct ClaudeCarry: Codable, Equatable, Sendable {
        struct Pending: Codable, Equatable, Sendable {
            var messageID: String
            var model: String
            var start: Double
            var end: Double
            var outputTokens: Int64
        }

        /// When the latest prompt or tool result was written: the request start.
        var lastUserAt: Double?
        /// End of the previous response; a follow-up call without a new user
        /// entry cannot have started before it.
        var lastEndAt: Double?
        var pending: Pending?
    }

    struct CodexCarry: Codable, Equatable, Sendable {
        var model: String?
        var requestStart: Double?
        /// Arrival of the last model-generated item in the current request.
        /// Usage is recorded after tools run, so this is the truer end time.
        var lastModelItemAt: Double?
        /// Newer Codex writes `token_usage_record`; its `token_count` events
        /// then repeat the same usage and must be ignored.
        var usesUsageRecords = false
        var lastTotalTokens: Int64?
    }

    // MARK: Claude Code

    static func consumeClaudeLine(
        _ bytes: UnsafeRawBufferPointer,
        _ range: Range<Int>,
        carry: inout ClaudeCarry,
        agentID: String,
        into buckets: inout [String: ThroughputBucket]
    ) {
        let fields = JSONFieldScanner.fields(bytes, in: range, keys: ["type", "timestamp", "message"])
        guard let typeRange = fields[0], let type = JSONFieldScanner.string(bytes, typeRange) else { return }
        switch type {
        case "user":
            guard let time = fields[1].flatMap({ JSONFieldScanner.string(bytes, $0) }).flatMap(parseTimestamp) else { return }
            finalizeClaude(carry: &carry, agentID: agentID, into: &buckets)
            carry.lastUserAt = time
        case "assistant":
            guard let time = fields[1].flatMap({ JSONFieldScanner.string(bytes, $0) }).flatMap(parseTimestamp),
                  let messageRange = fields[2] else { return }
            let message = JSONFieldScanner.fields(bytes, in: messageRange, keys: ["id", "model", "usage"])
            guard let id = message[0].flatMap({ JSONFieldScanner.string(bytes, $0) }),
                  let model = message[1].flatMap({ JSONFieldScanner.string(bytes, $0) }),
                  model != "<synthetic>" else { return }
            let output = message[2].flatMap { usage in
                JSONFieldScanner.fields(bytes, in: usage, keys: ["output_tokens"])[0]
            }.flatMap { JSONFieldScanner.int64(bytes, $0) } ?? 0

            if var pending = carry.pending, pending.messageID == id {
                pending.end = max(pending.end, time)
                pending.outputTokens = max(pending.outputTokens, output)
                carry.pending = pending
                return
            }
            finalizeClaude(carry: &carry, agentID: agentID, into: &buckets)
            guard let userAt = carry.lastUserAt else { return }
            let start = max(userAt, carry.lastEndAt ?? userAt)
            carry.pending = .init(messageID: id, model: model, start: start, end: time, outputTokens: output)
        default:
            return
        }
    }

    static func finalizeClaude(
        carry: inout ClaudeCarry,
        agentID: String,
        into buckets: inout [String: ThroughputBucket]
    ) {
        guard let pending = carry.pending else { return }
        carry.pending = nil
        carry.lastEndAt = pending.end
        record(
            agentID: agentID,
            model: pending.model,
            start: pending.start,
            end: pending.end,
            outputTokens: pending.outputTokens,
            into: &buckets
        )
    }

    // MARK: Codex

    private static let codexModelItemTypes: Set<String> = [
        "reasoning", "function_call", "custom_tool_call", "local_shell_call", "web_search_call"
    ]
    private static let codexToolOutputTypes: Set<String> = [
        "function_call_output", "custom_tool_call_output", "local_shell_call_output"
    ]

    static func consumeCodexLine(
        _ bytes: UnsafeRawBufferPointer,
        _ range: Range<Int>,
        carry: inout CodexCarry,
        agentID: String,
        into buckets: inout [String: ThroughputBucket]
    ) {
        let fields = JSONFieldScanner.fields(bytes, in: range, keys: ["type", "timestamp", "payload"])
        guard let type = fields[0].flatMap({ JSONFieldScanner.string(bytes, $0) }),
              let time = fields[1].flatMap({ JSONFieldScanner.string(bytes, $0) }).flatMap(parseTimestamp),
              let payloadRange = fields[2] else { return }
        let payload = JSONFieldScanner.fields(
            bytes,
            in: payloadRange,
            keys: ["type", "role", "model", "usage", "info"]
        )
        let payloadType = payload[0].flatMap { JSONFieldScanner.string(bytes, $0) }

        switch type {
        case "turn_context":
            if let model = payload[2].flatMap({ JSONFieldScanner.string(bytes, $0) }), !model.isEmpty {
                carry.model = model
            }
        case "event_msg":
            switch payloadType {
            case "task_started", "user_message":
                carry.requestStart = time
                carry.lastModelItemAt = nil
            case "token_count":
                guard !carry.usesUsageRecords,
                      let info = payload[4] else { return }
                let infoFields = JSONFieldScanner.fields(bytes, in: info, keys: ["last_token_usage", "total_token_usage"])
                let total = infoFields[1].flatMap { range in
                    JSONFieldScanner.fields(bytes, in: range, keys: ["total_tokens"])[0]
                }.flatMap { JSONFieldScanner.int64(bytes, $0) }
                if let total, total == carry.lastTotalTokens { return }
                carry.lastTotalTokens = total ?? carry.lastTotalTokens
                let output = infoFields[0].flatMap { range in
                    JSONFieldScanner.fields(bytes, in: range, keys: ["output_tokens"])[0]
                }.flatMap { JSONFieldScanner.int64(bytes, $0) } ?? 0
                completeCodexRequest(time: time, output: output, carry: &carry, agentID: agentID, into: &buckets)
            default:
                return
            }
        case "token_usage_record":
            carry.usesUsageRecords = true
            let output = payload[3].flatMap { range in
                JSONFieldScanner.fields(bytes, in: range, keys: ["output_tokens"])[0]
            }.flatMap { JSONFieldScanner.int64(bytes, $0) } ?? 0
            completeCodexRequest(time: time, output: output, carry: &carry, agentID: agentID, into: &buckets)
        case "response_item":
            guard let payloadType else { return }
            if payloadType == "message" {
                let role = payload[1].flatMap { JSONFieldScanner.string(bytes, $0) }
                if role == "assistant" { carry.lastModelItemAt = time }
            } else if codexModelItemTypes.contains(payloadType) {
                carry.lastModelItemAt = time
            } else if codexToolOutputTypes.contains(payloadType), carry.lastModelItemAt == nil {
                // Tool output logged between requests: the next request
                // cannot start before the tool finished.
                carry.requestStart = max(carry.requestStart ?? time, time)
            }
        default:
            return
        }
    }

    private static func completeCodexRequest(
        time: Double,
        output: Int64,
        carry: inout CodexCarry,
        agentID: String,
        into buckets: inout [String: ThroughputBucket]
    ) {
        defer {
            carry.requestStart = time
            carry.lastModelItemAt = nil
        }
        guard let start = carry.requestStart, let model = carry.model else { return }
        record(
            agentID: agentID,
            model: model,
            start: start,
            end: carry.lastModelItemAt ?? time,
            outputTokens: output,
            into: &buckets
        )
    }

    // MARK: Shared

    static func record(
        agentID: String,
        model: String,
        start: Double,
        end: Double,
        outputTokens: Int64,
        into buckets: inout [String: ThroughputBucket]
    ) {
        let duration = end - start
        guard outputTokens > 0,
              durationRange.contains(duration),
              Double(outputTokens) / duration <= maximumTokensPerSecond else { return }
        let key = ModelThroughputSnapshot.key(
            day: dayKey(Date(timeIntervalSince1970: end)),
            agentID: agentID,
            modelID: model
        )
        buckets[key, default: .init()].merge(
            ThroughputBucket(outputTokens: outputTokens, seconds: duration, samples: 1)
        )
    }

    /// Local calendar day, matching ccusage's `--timezone` day boundaries.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Fast path for `YYYY-MM-DDTHH:MM:SS(.fraction)Z`, the shape both CLIs
    /// write; anything else goes through ISO8601DateFormatter.
    static func parseTimestamp(_ text: String) -> Double? {
        let utf8 = Array(text.utf8)
        func digits(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= utf8.count else { return nil }
            var value = 0
            for index in from..<(from + count) {
                let byte = utf8[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        if utf8.count >= 20, utf8.last == 90, utf8[4] == 45, utf8[7] == 45, utf8[10] == 84,
           let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
           let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2) {
            var fraction = 0.0
            if utf8.count > 20, utf8[19] == 46 {
                var scale = 0.1
                for byte in utf8[20..<(utf8.count - 1)] {
                    guard byte >= 48, byte <= 57 else { return nil }
                    fraction += Double(byte - 48) * scale
                    scale /= 10
                }
            } else if utf8.count != 20 {
                return nil
            }
            // Days from civil (Howard Hinnant), proleptic Gregorian, UTC.
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mp = (month + 9) % 12
            let doy = (153 * mp + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            return Double(days * 86_400 + hour * 3_600 + minute * 60 + second) + fraction
        }
        return fallbackFormatter.date(from: text)?.timeIntervalSince1970
    }

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Extracts selected top-level members of one JSON object without building a
/// document tree. Values are returned as byte ranges; nested objects are
/// skipped by bracket counting, so large tool output costs one linear pass.
enum JSONFieldScanner {
    static func fields(
        _ bytes: UnsafeRawBufferPointer,
        in range: Range<Int>,
        keys: [StaticString]
    ) -> [Range<Int>?] {
        var result = [Range<Int>?](repeating: nil, count: keys.count)
        var found = 0
        let end = min(range.upperBound, bytes.count)
        var index = skipWhitespace(bytes, range.lowerBound, end)
        guard index < end, bytes[index] == UInt8(ascii: "{") else { return result }
        index += 1
        while index < end {
            index = skipWhitespace(bytes, index, end)
            guard index < end, bytes[index] == UInt8(ascii: "\"") else { return result }
            let keyStart = index + 1
            index = skipString(bytes, index, end)
            let keyEnd = index - 1
            index = skipWhitespace(bytes, index, end)
            guard index < end, bytes[index] == UInt8(ascii: ":") else { return result }
            index = skipWhitespace(bytes, index + 1, end)
            let valueStart = index
            index = skipValue(bytes, index, end)
            guard index > valueStart else { return result }
            if keyEnd >= keyStart {
                for (slot, key) in keys.enumerated() where result[slot] == nil {
                    if matches(bytes, keyStart..<keyEnd, key) {
                        result[slot] = valueStart..<index
                        found += 1
                        break
                    }
                }
                if found == keys.count { return result }
            }
            index = skipWhitespace(bytes, index, end)
            guard index < end, bytes[index] == UInt8(ascii: ",") else { return result }
            index += 1
        }
        return result
    }

    /// A JSON string value; escapes are decoded only when present.
    static func string(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> String? {
        guard range.count >= 2,
              bytes[range.lowerBound] == UInt8(ascii: "\""),
              bytes[range.upperBound - 1] == UInt8(ascii: "\"") else { return nil }
        let inner = (range.lowerBound + 1)..<(range.upperBound - 1)
        guard inner.count <= 4_096 else { return nil }
        let slice = UnsafeRawBufferPointer(rebasing: bytes[inner])
        if !slice.contains(UInt8(ascii: "\\")) {
            return String(decoding: slice, as: UTF8.self)
        }
        let quoted = Data(UnsafeRawBufferPointer(rebasing: bytes[range]))
        return try? JSONDecoder().decode(String.self, from: quoted)
    }

    static func int64(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> Int64? {
        guard !range.isEmpty, range.count <= 19 else { return nil }
        var value: Int64 = 0
        for index in range {
            let byte = bytes[index]
            guard byte >= 48, byte <= 57 else { return nil }
            value = value * 10 + Int64(byte - 48)
        }
        return value
    }

    private static func matches(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>, _ key: StaticString) -> Bool {
        guard range.count == key.utf8CodeUnitCount else { return false }
        let pointer = key.utf8Start
        for offset in 0..<range.count where bytes[range.lowerBound + offset] != pointer[offset] {
            return false
        }
        return true
    }

    private static func skipWhitespace(_ bytes: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> Int {
        var index = start
        while index < end {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return index
            }
        }
        return index
    }

    /// `start` is at the opening quote; returns the index after the closing one.
    private static func skipString(_ bytes: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> Int {
        var index = start + 1
        while index < end {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                index += 2
            } else if byte == UInt8(ascii: "\"") {
                return index + 1
            } else {
                index += 1
            }
        }
        return end
    }

    private static func skipValue(_ bytes: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> Int {
        guard start < end else { return start }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return skipString(bytes, start, end)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < end {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index = skipString(bytes, index, end)
                    continue
                }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    depth += 1
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return index + 1 }
                }
                index += 1
            }
            return end
        default:
            var index = start
            while index < end {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D:
                    return index
                default:
                    index += 1
                }
            }
            return index
        }
    }
}
