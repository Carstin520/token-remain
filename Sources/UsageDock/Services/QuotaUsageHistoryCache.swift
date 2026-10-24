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

/// Every refresh replaces the open fifteen-minute bucket's sample for each
/// provider, so writing the whole multi-megabyte cache after every provider
/// result rewrote the same rows several times a minute (about 2.7 GB a day on
/// a busy Mac). The in-memory history stays live; the file trails it by at
/// most `writeDelay` and is flushed when the app terminates. Encoding runs
/// off the main thread. A zero delay writes through, as before.
final class QuotaUsageHistoryWriter: @unchecked Sendable {
    static let defaultWriteDelay: TimeInterval = 5 * 60

    private let cache: QuotaUsageHistoryCache
    private let writeDelay: TimeInterval
    private let queue = DispatchQueue(
        label: "com.jamesli.usagedock.quota-history-writer",
        qos: .utility
    )
    private let lock = NSLock()
    private var pending: QuotaUsageHistory?
    private var writeScheduled = false

    init(cache: QuotaUsageHistoryCache, writeDelay: TimeInterval = defaultWriteDelay) {
        self.cache = cache
        self.writeDelay = writeDelay
    }

    func schedule(_ history: QuotaUsageHistory) {
        guard writeDelay > 0 else {
            cache.save(history)
            return
        }
        lock.lock()
        pending = history
        let needsWrite = !writeScheduled
        writeScheduled = true
        lock.unlock()
        guard needsWrite else { return }
        queue.asyncAfter(deadline: .now() + writeDelay) { [weak self] in
            self?.writePending()
        }
    }

    /// Writes any pending history before returning.
    func flush() {
        queue.sync { writePending() }
    }

    private func writePending() {
        lock.lock()
        let history = pending
        pending = nil
        writeScheduled = false
        lock.unlock()
        if let history {
            cache.save(history)
        }
    }
}
