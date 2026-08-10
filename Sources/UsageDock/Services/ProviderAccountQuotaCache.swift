import Foundation

struct ProviderAccountQuotaCache: Sendable {
    private struct Payload: Codable {
        let quotas: [String: ProviderQuota]
    }

    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.url = caches
                .appending(path: "com.jamesli.usagedock", directoryHint: .isDirectory)
                .appending(path: "provider-account-quota-cache-v1.json")
        }
    }

    func load() -> [ProviderAccountID: ProviderQuota] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: payload.quotas.map {
            (ProviderAccountID(rawValue: $0.key), $0.value)
        })
    }

    func save(_ quotas: [ProviderAccountID: ProviderQuota]) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = Payload(quotas: Dictionary(uniqueKeysWithValues: quotas.map {
                ($0.key.rawValue, $0.value)
            }))
            try JSONEncoder().encode(payload).write(to: url, options: .atomic)
        } catch {
            // A cache failure must never affect live provider refreshes.
        }
    }
}
