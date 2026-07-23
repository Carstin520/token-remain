import Foundation

struct QuotaCache: Sendable {
    /// v2:按 provider rawValue 存字典;仍能读取 v1 的逐字段格式
    /// (键名恰与当年的字段名一致,直接按 rawValue 映射兜底)。
    struct Snapshot: Codable, Sendable {
        var byProvider: [ProviderQuota.Provider: ProviderQuota]

        init(byProvider: [ProviderQuota.Provider: ProviderQuota]) {
            self.byProvider = byProvider
        }

        enum CodingKeys: String, CodingKey {
            case quotas
            // v1 逐字段键
            case claude, codex, cursor, grok, zai
            case copilot, devin, openrouter, antigravity, opencode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let raw = try container.decodeIfPresent([String: ProviderQuota].self, forKey: .quotas) {
                var map: [ProviderQuota.Provider: ProviderQuota] = [:]
                for (key, value) in raw {
                    if let provider = ProviderQuota.Provider(rawValue: key) {
                        map[provider] = value
                    }
                }
                byProvider = map
                return
            }
            var map: [ProviderQuota.Provider: ProviderQuota] = [:]
            let legacy: [(CodingKeys, ProviderQuota.Provider)] = [
                (.claude, .claude), (.codex, .codex), (.cursor, .cursor),
                (.grok, .grok), (.zai, .zai), (.copilot, .copilot),
                (.devin, .devin), (.openrouter, .openrouter),
                (.antigravity, .antigravity), (.opencode, .opencode)
            ]
            for (key, provider) in legacy {
                if let quota = try container.decodeIfPresent(ProviderQuota.self, forKey: key) {
                    map[provider] = quota
                }
            }
            byProvider = map
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let raw = Dictionary(uniqueKeysWithValues: byProvider.map { ($0.key.rawValue, $0.value) })
            try container.encode(raw, forKey: .quotas)
        }
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
