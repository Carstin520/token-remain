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
            logger.info("Codex quota served by wham/usage API")
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
            // 于其修改时间,所以一旦拿到的账户级快照比剩余文件都新,后
            // 面的文件就不可能再翻盘,直接停。稳定状态下每轮只解析最近
            // 活跃的一两个会话文件,其余靠 mtime 未变的缓存直接复用。
            candidates.sort { $0.modifiedAt > $1.modifiedAt }

            // Codex emits both the general account quota (`limit_id = codex`) and
            // model-specific limits such as `codex_bengalfox`. A newer model-specific
            // event must never replace the general quota card.
            var newestCanonical: Snapshot?
            var newestLegacy: Snapshot?
            for candidate in candidates {
                if let canonical = newestCanonical, canonical.capturedAt >= candidate.modifiedAt {
                    break
                }
                for snapshot in CodexSnapshotFileCache.shared.snapshots(
                    in: candidate.url,
                    modifiedAt: candidate.modifiedAt
                ) {
                    if snapshot.limitID?.lowercased() == "codex" {
                        if newestCanonical.map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                            newestCanonical = snapshot
                        }
                    } else if (snapshot.limitID?.isEmpty ?? true), (snapshot.limitName?.isEmpty ?? true) {
                        // Older Codex versions did not include limit_id. Retain a
                        // narrow legacy fallback, but reject named model limits so
                        // they cannot masquerade as the account-wide quota.
                        if newestLegacy.map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                            newestLegacy = snapshot
                        }
                    }
                }
            }

            if let newestCanonical { return newestCanonical.quota }
            if let newestLegacy { return newestLegacy.quota }
            throw ProcessRunner.Failure(message: L10n.text("service.codex.snapshot_missing"))
        }.value
    }

    private struct Snapshot {
        let quota: ProviderQuota
        let capturedAt: Date
        let limitID: String?
        let limitName: String?
    }

    /// 按 (文件, 修改时间) 复用尾部解析结果:mtime 未变的会话文件不再
    /// 重复读取。fetch 的早停让每轮真正触达的文件极少,缓存因此始终
    /// 很小;条目上限只是防御性兜底。
    private final class CodexSnapshotFileCache: @unchecked Sendable {
        static let shared = CodexSnapshotFileCache()

        private struct Entry {
            let modifiedAt: Date
            let snapshots: [Snapshot]
        }

        private let lock = NSLock()
        private var entries: [URL: Entry] = [:]

        func snapshots(in url: URL, modifiedAt: Date) -> [Snapshot] {
            lock.lock()
            let cached = entries[url]
            lock.unlock()
            if let cached, cached.modifiedAt == modifiedAt {
                return cached.snapshots
            }
            let parsed = (try? CodexUsageService.parseNewestSnapshots(in: url)) ?? []
            lock.lock()
            if entries.count >= 64 { entries.removeAll() }
            entries[url] = Entry(modifiedAt: modifiedAt, snapshots: parsed)
            lock.unlock()
            return parsed
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
              let percent = (object["used_percent"] as? NSNumber)?.doubleValue,
              let reset = (object["resets_at"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (object["window_minutes"] as? NSNumber)?.intValue ?? fallbackMinutes
        return QuotaWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: Date(timeIntervalSince1970: reset))
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
