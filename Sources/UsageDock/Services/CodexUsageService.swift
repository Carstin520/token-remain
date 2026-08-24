import Foundation
import OSLog

struct CodexUsageService {
    /// 主路径:wham/usage API 直查(只读 auth.json,实时的 5 小时 + 7 天窗口)。
    /// 未登录/token 过期/网络失败时降级本地会话快照——离线可用,但只在
    /// Codex 产生服务端事件时更新,可能滞后或缺少部分窗口。
    ///
    /// `preferAPI: false` 只扫本地快照,供 UsageStore 的分钟级轮次在两次
    /// API 直查之间补新,避免每分钟都打服务端接口。
    func fetch(preferAPI: Bool = true) async throws -> ProviderQuota {
        guard preferAPI else {
            return try await fetchFromLocalSnapshots()
        }
        let logger = Logger(subsystem: "com.jamesli.usagedock", category: "CodexUsage")
        do {
            let quota = try await CodexAPIUsageService().fetch()
            // The account-wide API does not currently expose every model-scoped
            // cap. Codex's local token_count events do, so merge only those
            // supplemental windows while keeping the API's primary/secondary
            // values authoritative.
            if let local = try? await fetchFromLocalSnapshots() {
                let activeScopedWindows = local.uniqueScopedWindows.filter { scoped in
                    scoped.window.resetsAt.map { $0 > quota.capturedAt } ?? true
                }
                let supplemented = quota.mergingScopedWindows(activeScopedWindows)
                logger.info("Codex quota served by wham/usage API; model-scoped limits: \(supplemented.uniqueScopedWindows.count, privacy: .public)")
                return supplemented
            }
            logger.info("Codex quota served by wham/usage API; model-scoped limits unavailable")
            return quota
        } catch let apiError {
            logger.info("Codex API path failed (\(apiError.localizedDescription, privacy: .public)); falling back to local snapshots")
            do {
                return try await fetchFromLocalSnapshots()
            } catch {
                // 两条路径都失败时,API 侧的原因(未登录/过期/HTTP 状态)
                // 比"找不到快照"更能指导用户下一步动作。
                throw apiError
            }
        }
    }

    func fetchFromLocalSnapshots() async throws -> ProviderQuota {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return try await Self.fetch(from: [
            home.appending(path: ".codex/sessions"),
            home.appending(path: ".codex/archived_sessions")
        ])
    }

    static func fetch(from roots: [URL]) async throws -> ProviderQuota {
        try await Task.detached(priority: .utility) {
            var candidates: [(url: URL, modifiedAt: Date)] = []

            for root in roots {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension == "jsonl" else { continue }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    candidates.append((url, values?.contentModificationDate ?? .distantPast))
                }
            }

            // 这套扫描每分钟都在跑,绝不能每轮把全部历史会话的尾部重新
            // 解析一遍。按修改时间从新到旧遍历:文件内事件的时间不会晚
            // 于其修改时间,所以已拿到的账户级快照一旦比剩余文件新出
            // 一个宽容窗,后面的文件就不可能再翻盘,直接停。宽容窗吸收
            // 系统时钟回拨造成的 mtime 早于事件时间:一天以内的回拨不
            // 影响正确性,只是多解析几个近期文件(且多为缓存命中)。
            candidates.sort { $0.modifiedAt > $1.modifiedAt }
            let cache = CodexSnapshotFileCache.shared
            let changedCandidates = cache.changedCandidatesSinceLastScan(
                candidates,
                under: roots
            )
            cache.prune(
                under: roots,
                keeping: Set(candidates.map(\.url))
            )

            // Codex emits both the general account quota (`limit_id = codex`) and
            // model-specific limits such as `codex_bengalfox`. A newer model-specific
            // event must never replace the general quota card, but its weekly window
            // should remain visible as a named child row.
            var newestCanonical: Snapshot?
            var newestLegacy: Snapshot?
            var newestScopedByID: [String: Snapshot] = [:]

            func consider(_ snapshot: Snapshot) {
                if snapshot.limitID?.lowercased() == "codex" {
                    if newestCanonical.map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                        newestCanonical = snapshot
                    }
                } else if (snapshot.limitID?.isEmpty ?? true),
                          (snapshot.limitName?.isEmpty ?? true) {
                    // Older Codex versions did not include limit_id. Retain a
                    // narrow legacy fallback, but reject named model limits so
                    // they cannot masquerade as the account-wide quota.
                    if newestLegacy.map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                        newestLegacy = snapshot
                    }
                } else if let scopeID = scopedID(for: snapshot) {
                    if newestScopedByID[scopeID].map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                        newestScopedByID[scopeID] = snapshot
                    }
                }
            }

            // Once this root has a cache baseline, every new or rewritten file
            // must be inspected once even when its mtime moved backwards by more
            // than the ordinary early-stop skew allowance. This keeps the fast
            // cached traversal while making a newly created session impossible
            // to hide behind a stale filesystem clock.
            for candidate in changedCandidates {
                for snapshot in cache.snapshots(
                    in: candidate.url,
                    modifiedAt: candidate.modifiedAt
                ) {
                    consider(snapshot)
                }
            }

            var traversalCanonical: Snapshot?
            for candidate in candidates {
                if let canonical = traversalCanonical,
                   canonical.capturedAt.timeIntervalSince(candidate.modifiedAt) > Self.earlyStopSkewAllowance {
                    break
                }
                for snapshot in cache.snapshots(
                    in: candidate.url,
                    modifiedAt: candidate.modifiedAt
                ) {
                    consider(snapshot)
                    if snapshot.limitID?.lowercased() == "codex",
                       traversalCanonical.map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                        traversalCanonical = snapshot
                    }
                }
            }

            guard let base = newestCanonical ?? newestLegacy else {
                throw ProcessRunner.Failure(message: L10n.text("service.codex.snapshot_missing"))
            }
            let scopedWindows = newestScopedByID.values
                .flatMap { Self.scopedWindows(from: $0, relativeTo: base.capturedAt) }
                .sorted { lhs, rhs in
                    // 同一模型的 session/weekly 成对相邻,短窗在前,与主卡
                    // 5h+7d 的顺序一致。
                    let names = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    guard names == .orderedSame else { return names == .orderedAscending }
                    return lhs.window.windowMinutes < rhs.window.windowMinutes
                }
            return base.quota.mergingScopedWindows(scopedWindows)
        }.value
    }

    private struct Snapshot {
        let quota: ProviderQuota
        let capturedAt: Date
        let limitID: String?
        let limitName: String?
    }

    /// 早停允许剩余文件的 mtime 比已得快照最多早这么久仍被解析,用来
    /// 吸收"时钟回拨期间写入的文件 mtime 早于其事件时间"的异常;超过
    /// 一天的回拨。超过一天的新建/改写文件由候选元数据基线单独保证会
    /// 解析一次，不需要牺牲正常路径的早停。
    private static let earlyStopSkewAllowance: TimeInterval = 24 * 60 * 60

    /// 按 (文件, 修改时间) 复用尾部解析结果:mtime 未变的会话文件不再
    /// 重复读取。条目随每轮扫描按现存候选集修剪,已删除的会话不会在
    /// 内存里残留。
    private final class CodexSnapshotFileCache: @unchecked Sendable {
        static let shared = CodexSnapshotFileCache()

        private struct Entry {
            let modifiedAt: Date
            let snapshots: [Snapshot]
        }

        private let lock = NSLock()
        private var entries: [URL: Entry] = [:]
        /// Full candidate metadata is cheap to retain and distinguishes a truly
        /// new/rewritten rollback file from untouched historical files that the
        /// parse early-stop intentionally never opened.
        private var knownModificationDates: [URL: Date] = [:]

        func changedCandidatesSinceLastScan(
            _ candidates: [(url: URL, modifiedAt: Date)],
            under roots: [URL]
        ) -> [(url: URL, modifiedAt: Date)] {
            let rootPaths = roots.map(Self.directoryPrefix)
            let currentURLs = Set(candidates.map(\.url))
            lock.lock()
            let hadBaseline = knownModificationDates.keys.contains { key in
                let keyPath = key.resolvingSymlinksInPath().path
                return rootPaths.contains { keyPath.hasPrefix($0) }
            }
            let changed = hadBaseline ? candidates.filter { candidate in
                knownModificationDates[candidate.url] != candidate.modifiedAt
            } : []
            knownModificationDates = knownModificationDates.filter { key, _ in
                let keyPath = key.resolvingSymlinksInPath().path
                let underRoot = rootPaths.contains { keyPath.hasPrefix($0) }
                return !underRoot || currentURLs.contains(key)
            }
            for candidate in candidates {
                knownModificationDates[candidate.url] = candidate.modifiedAt
            }
            lock.unlock()
            return changed
        }

        func snapshots(in url: URL, modifiedAt: Date) -> [Snapshot] {
            lock.lock()
            let cached = entries[url]
            lock.unlock()
            if let cached, cached.modifiedAt == modifiedAt {
                return cached.snapshots
            }
            let parsed = (try? CodexUsageService.parseNewestSnapshots(in: url)) ?? []
            lock.lock()
            entries[url] = Entry(modifiedAt: modifiedAt, snapshots: parsed)
            lock.unlock()
            return parsed
        }

        /// 只修剪本次扫描 root 之下、且已不在候选集里的条目(文件被
        /// 删除/归档)。范围必须限定在 root 内:并发的另一组目录扫描
        /// (以及并行测试)不允许把彼此的活条目清掉。
        func prune(under roots: [URL], keeping urls: Set<URL>) {
            let rootPaths = roots.map(Self.directoryPrefix)
            lock.lock()
            entries = entries.filter { key, _ in
                let keyPath = key.resolvingSymlinksInPath().path
                let underRoot = rootPaths.contains { keyPath.hasPrefix($0) }
                return !underRoot || urls.contains(key)
            }
            lock.unlock()
        }

        private static func directoryPrefix(for url: URL) -> String {
            let path = url.resolvingSymlinksInPath().path
            return path.hasSuffix("/") ? path : path + "/"
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackTimestampFormatter = ISO8601DateFormatter()

    private static func parseNewestSnapshots(in url: URL) throws -> [Snapshot] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        // The newest token_count event is appended near the end of each JSONL session.
        // Keeping this bounded lets us refresh every minute without repeatedly loading all
        // historical Codex transcripts into memory.
        let readSize = min(length, 512 * 1_024)
        try handle.seek(toOffset: length - readSize)
        let data = try handle.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var snapshotsByLimit: [String: Snapshot] = [:]
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  let primary = parseWindow(limits["primary"], fallbackMinutes: 300) else { continue }

            let limitID = normalizedString(limits["limit_id"])
            let limitName = normalizedString(limits["limit_name"])
            let limitKey = "\(limitID ?? "<legacy>")|\(limitName ?? "")"
            guard snapshotsByLimit[limitKey] == nil else { continue }

            let secondary = parseWindow(limits["secondary"], fallbackMinutes: 10_080)
            let capturedAt = parseTimestamp(object["timestamp"] as? String)
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            snapshotsByLimit[limitKey] = Snapshot(
                quota: ProviderQuota(
                    provider: .codex,
                    primary: primary,
                    secondary: secondary,
                    planName: limits["plan_type"] as? String,
                    capturedAt: capturedAt
                ),
                capturedAt: capturedAt,
                limitID: limitID,
                limitName: limitName
            )
        }
        return Array(snapshotsByLimit.values)
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return timestampFormatter.date(from: value) ?? fallbackTimestampFormatter.date(from: value)
    }

    private static func parseWindow(_ value: Any?, fallbackMinutes: Int) -> QuotaWindow? {
        guard let object = value as? [String: Any],
              let percent = (object["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (object["window_minutes"] as? NSNumber)?.intValue ?? fallbackMinutes
        // `resets_at` 缺失或为 null 时不再丢弃整个窗口:QuotaWindow.resetsAt
        // 本身就是 Optional,解析器不应比模型更严格。
        let reset = (object["resets_at"] as? NSNumber)?.doubleValue
        return QuotaWindow(
            usedPercent: percent,
            windowMinutes: minutes,
            resetsAt: reset.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func scopedID(for snapshot: Snapshot) -> String? {
        guard let displayName = snapshot.limitName else { return nil }
        if let limitID = snapshot.limitID?.lowercased(), limitID != "codex" {
            return limitID
        }
        let normalized = displayName.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return normalized.isEmpty ? nil : normalized
    }

    /// 模型级快照(如 `codex_bengalfox`)的 5h 与 7d 两窗都保留,成对生成
    /// scoped 行:scopeID 加 `_session` / `_weekly` 后缀,displayName 一律用
    /// 模型名。UI 会按各自窗口时长渲染成 "GPT-5.3-Codex-Spark · 5 hr" 与
    /// "· 7 d",与主卡 5h+7d 的堆叠习惯一致;只有一个窗的快照生成一条,
    /// 按时长归入对应后缀(历史上模型池的周窗也会单独出现在 primary 槽)。
    private static func scopedWindows(
        from snapshot: Snapshot,
        relativeTo baseCapturedAt: Date
    ) -> [ScopedQuotaWindow] {
        guard let baseScopeID = scopedID(for: snapshot),
              let displayName = snapshot.limitName else { return [] }
        let scopePrefix = wireScopeBase(for: baseScopeID)
        let pairs: [(suffix: String, window: QuotaWindow)]
        if let secondary = snapshot.quota.secondary {
            pairs = [
                ("_session", snapshot.quota.primary),
                ("_weekly", secondary)
            ]
        } else {
            let primary = snapshot.quota.primary
            pairs = [(primary.windowMinutes >= 10_080 ? "_weekly" : "_session", primary)]
        }
        return pairs.compactMap { suffix, window in
            // A model limit can linger in an old session forever. Do not attach
            // it to a fresh account snapshot after its last reported reset has
            // passed.
            guard window.resetsAt.map({ $0 > baseCapturedAt }) ?? true else { return nil }
            return ScopedQuotaWindow(
                scopeID: scopePrefix + suffix,
                displayName: displayName,
                window: window,
                observedAt: snapshot.capturedAt
            )
        }
    }

    /// scopeID 上限 32 字符([a-z0-9_-]{1,32}),给最长的 `_session` 后缀
    /// 预留 8 个字符,基底必须 ≤24。历史实现直接截前 24 字符:两个前
    /// 24 字符相同的长 limit_id 会得到同一个 scopeID,uniqueScopedWindows
    /// 随即把不同模型池折叠成一个。改为 前 15 字符 + "_" + FNV-1a 32 位
    /// 哈希(8 位十六进制),哈希覆盖完整 id,总长恰 24;15 字符前缀恰
    /// 好保住 `isCodexSpark` 的 hasPrefix("codex_bengalfox") 判定
    /// ("codex_bengalfox" 正是 15 字符)。≤24 字节的 id 原样使用,现有
    /// scopeID 不受影响。
    static func wireScopeBase(for baseScopeID: String) -> String {
        guard baseScopeID.utf8.count > 24 else { return baseScopeID }
        return String(baseScopeID.prefix(15)) + "_" + fnv1a32Hex(baseScopeID)
    }

    /// FNV-1a 32 位哈希。必须自实现:Swift 的 `Hasher` 每次进程启动随机
    /// 化种子,而 scopeID 会进缓存并跨设备同步,要求跨进程、跨版本稳定。
    private static func fnv1a32Hex(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }
}
