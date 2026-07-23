import Foundation

enum AIFeedTier: String, Codable, Hashable, Sendable, CaseIterable {
    case primary
    case rotating

    var title: String {
        switch self {
        case .primary: return L10n.text("feed.tier.primary")
        case .rotating: return L10n.text("feed.tier.rotating")
        }
    }
}

enum AIFeedPriority: String, Codable, Hashable, Sendable {
    case tokenReset
    case majorUpdate
    case normal

    var rank: Int {
        switch self {
        case .tokenReset: return 0
        case .majorUpdate: return 1
        case .normal: return 2
        }
    }

    var title: String {
        switch self {
        case .tokenReset: return L10n.text("feed.priority.token")
        case .majorUpdate: return L10n.text("feed.priority.update")
        case .normal: return L10n.text("feed.priority.normal")
        }
    }
}

struct AIFeedMetrics: Codable, Hashable, Sendable {
    let likes: Int
    let reposts: Int
    let replies: Int
}

struct AIFeedPost: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let text: String
    let username: String
    let displayName: String
    let createdAt: Date
    let metrics: AIFeedMetrics
    let priority: AIFeedPriority
    let externalURL: URL?
    let tier: AIFeedTier

    init(
        id: String,
        text: String,
        username: String,
        displayName: String,
        createdAt: Date,
        metrics: AIFeedMetrics,
        priority: AIFeedPriority,
        externalURL: URL?,
        tier: AIFeedTier = .primary
    ) {
        self.id = id
        self.text = text
        self.username = username
        self.displayName = displayName
        self.createdAt = createdAt
        self.metrics = metrics
        self.priority = priority
        self.externalURL = externalURL
        self.tier = tier
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, username, displayName, createdAt, metrics, priority, externalURL, tier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decode(String.self, forKey: .displayName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        metrics = try container.decode(AIFeedMetrics.self, forKey: .metrics)
        priority = try container.decode(AIFeedPriority.self, forKey: .priority)
        externalURL = try container.decodeIfPresent(URL.self, forKey: .externalURL)
        tier = try container.decodeIfPresent(AIFeedTier.self, forKey: .tier) ?? .primary
    }

    var postURL: URL {
        externalURL ?? URL(string: "https://x.com/\(username)/status/\(id)")!
    }

    var initials: String {
        let parts = displayName.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? String(username.prefix(1)).uppercased() : String(letters).uppercased()
    }

    static func sortedForDisplay(_ posts: [AIFeedPost]) -> [AIFeedPost] {
        posts.sorted {
            if $0.priority.rank != $1.priority.rank {
                return $0.priority.rank < $1.priority.rank
            }
            return $0.createdAt > $1.createdAt
        }
    }
}
