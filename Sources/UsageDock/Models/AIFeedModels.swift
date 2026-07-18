import Foundation

enum AIFeedTier: String, Codable, Hashable, Sendable, CaseIterable {
    case primary
    case rotating

    var title: String {
        switch self {
        case .primary: return "第一梯队"
        case .rotating: return "第二梯队"
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
        case .tokenReset: return "额度 / Token"
        case .majorUpdate: return "重大更新"
        case .normal: return "动态"
        }
    }
}

struct AIFeedAccount: Identifiable, Codable, Hashable, Sendable {
    let username: String
    let displayName: String

    var id: String { username.lowercased() }

    var profileURL: URL {
        URL(string: "https://x.com/\(username)")!
    }

    static let primary: [AIFeedAccount] = [
        .init(username: "btibor91", displayName: "Tibor Blaho"),
        .init(username: "sama", displayName: "Sam Altman"),
        .init(username: "claudeai", displayName: "Claude"),
        .init(username: "AnthropicAI", displayName: "Anthropic"),
        .init(username: "OpenAI", displayName: "OpenAI"),
        .init(username: "thsottiaux", displayName: "Tibo"),
        .init(username: "karpathy", displayName: "Andrej Karpathy")
    ]

    static let rotatingCandidates: [AIFeedAccount] = [
        .init(username: "elonmusk", displayName: "Elon Musk"),
        .init(username: "Kimi_Moonshot", displayName: "Kimi"),
        .init(username: "AIatMeta", displayName: "AI at Meta"),
        .init(username: "GoogleDeepMind", displayName: "Google DeepMind"),
        .init(username: "xai", displayName: "xAI"),
        .init(username: "MistralAI", displayName: "Mistral AI"),
        .init(username: "deepseek_ai", displayName: "DeepSeek"),
        .init(username: "OpenRouterAI", displayName: "OpenRouter"),
        .init(username: "perplexity_ai", displayName: "Perplexity"),
        .init(username: "simonw", displayName: "Simon Willison"),
        .init(username: "emollick", displayName: "Ethan Mollick"),
        .init(username: "ArtificialAnlys", displayName: "Artificial Analysis")
    ]

    static let monitored = primary + rotatingCandidates

    static func tier(for username: String) -> AIFeedTier {
        let normalized = username.lowercased()
        return primary.contains { $0.username.lowercased() == normalized }
            ? .primary
            : .rotating
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
        tier = try container.decodeIfPresent(AIFeedTier.self, forKey: .tier)
            ?? AIFeedAccount.tier(for: username)
    }

    var postURL: URL {
        externalURL ?? URL(string: "https://x.com/\(username)/status/\(id)")!
    }

    func applyingConfiguredTier() -> AIFeedPost {
        let configuredTier = AIFeedAccount.tier(for: username)
        guard configuredTier != tier else { return self }
        return AIFeedPost(
            id: id,
            text: text,
            username: username,
            displayName: displayName,
            createdAt: createdAt,
            metrics: metrics,
            priority: priority,
            externalURL: externalURL,
            tier: configuredTier
        )
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
