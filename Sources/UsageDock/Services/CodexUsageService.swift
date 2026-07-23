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
            var candidates: [URL] = []

            for root in roots {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension == "jsonl" else { continue }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    if values?.isRegularFile == true {
                        candidates.append(url)
                    }
                }
            }

            // Codex emits both the general account quota (`limit_id = codex`) and
            // model-specific limits such as `codex_bengalfox`. A newer model-specific
            // event must never replace the general quota card.
            let snapshots = candidates.flatMap { (try? Self.parseNewestSnapshots(in: $0)) ?? [] }
            let canonical = snapshots.filter { $0.limitID?.lowercased() == "codex" }
            if let newest = canonical.max(by: { $0.capturedAt < $1.capturedAt }) {
                return newest.quota
            }

            // Older Codex versions did not include limit_id. Retain a narrow legacy
            // fallback, but reject named model limits so they cannot masquerade as the
            // account-wide quota.
            let legacy = snapshots.filter {
                ($0.limitID?.isEmpty ?? true) && ($0.limitName?.isEmpty ?? true)
            }
            if let newest = legacy.max(by: { $0.capturedAt < $1.capturedAt }) {
                return newest.quota
            }
            throw ProcessRunner.Failure(message: L10n.text("service.codex.snapshot_missing"))
        }.value
    }

    private struct Snapshot {
        let quota: ProviderQuota
        let capturedAt: Date
        let limitID: String?
        let limitName: String?
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
