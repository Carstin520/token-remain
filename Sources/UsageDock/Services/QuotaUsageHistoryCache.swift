import Foundation

/// Best-effort local persistence for quota-percentage history. Provider
/// credentials and raw responses never enter this cache.
struct QuotaUsageHistoryCache: Sendable {
    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.url = caches
                .appending(path: "com.jamesli.usagedock", directoryHint: .isDirectory)
                .appending(path: "quota-usage-history-v1.json")
        }
    }

    func load() -> QuotaUsageHistory? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(QuotaUsageHistory.self, from: data)
    }

    func save(_ history: QuotaUsageHistory) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(history)
            try data.write(to: url, options: .atomic)
        } catch {
            // Trend persistence must never block live provider refreshes.
        }
    }
}
