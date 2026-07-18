import Foundation

struct QuotaCache: Sendable {
    struct Snapshot: Codable, Sendable {
        var claude: ProviderQuota?
        var codex: ProviderQuota?
    }

    private let url: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        url = caches
            .appending(path: "com.jamesli.usagedock", directoryHint: .isDirectory)
            .appending(path: "quota-cache.json")
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache failures must never block live usage updates.
        }
    }
}
