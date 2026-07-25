import Foundation
import TokenRemainSyncKit

/// Main-app-only persistence for owner-curated public X links. The feed never enters
/// the App Group, Widget, Live Activity, or Watch snapshot surfaces.
struct MobileCuratedFeedStore: Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = base.appendingPathComponent("TokenRemain", isDirectory: true)
        }
    }

    static let shared = MobileCuratedFeedStore()

    private var fileURL: URL {
        directory.appendingPathComponent("curated-x-feed-v1.json")
    }

    func load(now: Date = Date()) -> SyncedCuratedFeed? {
        guard let data = try? Data(contentsOf: fileURL),
              let feed = try? JSONDecoder.syncPayload.decode(SyncedCuratedFeed.self, from: data),
              Self.isValid(feed, now: now) else {
            return nil
        }
        return feed
    }

    func replace(with feed: SyncedCuratedFeed?, now: Date = Date()) {
        guard let feed else {
            clear()
            return
        }
        guard Self.isValid(feed, now: now),
              let data = try? JSONEncoder.syncPayload.encode(feed) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func isValid(_ feed: SyncedCuratedFeed, now: Date) -> Bool {
        let probe = MobileUsageSnapshot(
            sourceInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            sequence: 1,
            generatedAt: now,
            expiresAt: now.addingTimeInterval(60),
            providers: [],
            curatedFeed: feed
        )
        return (try? probe.validatedForTransport(configuration: .current(now: now))) != nil
    }
}

private extension JSONEncoder {
    static var syncPayload: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var syncPayload: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
