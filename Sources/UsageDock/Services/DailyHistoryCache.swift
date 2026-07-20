import Foundation

/// On-disk cache for the multi-day usage history so the Trends chart can paint
/// immediately on launch (before the first ccusage refresh completes) and
/// survive a transient ccusage failure. Mirrors `QuotaCache`'s best-effort,
/// never-throwing behavior — a cache miss simply falls back to a live fetch.
struct DailyHistoryCache: Sendable {
    private let url: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        url = caches
            .appending(path: "com.jamesli.usagedock", directoryHint: .isDirectory)
            .appending(path: "daily-history-cache.json")
    }

    func load() -> DailyUsageHistory? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DailyUsageHistory.self, from: data)
    }

    func save(_ history: DailyUsageHistory) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(history)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache failures must never block live usage updates.
        }
    }
}
