import Foundation

struct AIFeedCachePayload: Codable, Sendable {
    var posts: [AIFeedPost]
    var seenIDs: Set<String>
    var lastUpdated: Date?
    var selectedRotatingUsernames: [String]? = nil
    var selectionDayKey: String? = nil
}

struct AIFeedCache: Sendable {
    private let url: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent("com.jamesli.usagedock", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("ai-feed.json")
    }

    func load() -> AIFeedCachePayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AIFeedCachePayload.self, from: data)
    }

    func save(_ payload: AIFeedCachePayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
