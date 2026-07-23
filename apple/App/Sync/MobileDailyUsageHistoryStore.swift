import Foundation
import TokenRemainSyncKit

/// Main-app-only persistence for decrypted daily aggregates. This deliberately
/// lives outside the shared App Group, so Widget, Live Activity and Watch code
/// keep consuming only the current quota snapshot.
struct MobileDailyUsageHistoryStore: Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = base.appendingPathComponent(
                "TokenRemain",
                isDirectory: true
            )
        }
    }

    static let shared = MobileDailyUsageHistoryStore()

    private var fileURL: URL {
        directory.appendingPathComponent("daily-usage-history-v1.json")
    }

    func load(now: Date = Date()) -> SyncedDailyUsageHistory? {
        guard let data = try? Data(contentsOf: fileURL),
              let history = try? JSONDecoder.syncPayload.decode(
                SyncedDailyUsageHistory.self,
                from: data
              ),
              Self.isValid(history, now: now) else {
            return nil
        }
        return history
    }

    func replace(with history: SyncedDailyUsageHistory?, now: Date = Date()) {
        guard let history else {
            clear()
            return
        }
        guard Self.isValid(history, now: now),
              let data = try? JSONEncoder.syncPayload.encode(history) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func isValid(
        _ history: SyncedDailyUsageHistory,
        now: Date
    ) -> Bool {
        let probe = MobileUsageSnapshot(
            sourceInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            sequence: 1,
            generatedAt: now,
            expiresAt: now.addingTimeInterval(60),
            providers: [],
            dailyUsageHistory: history
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
