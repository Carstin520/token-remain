import Foundation

struct XFeedService: Sendable {
    struct TieredResult: Sendable {
        let posts: [AIFeedPost]
        let selectedRotatingUsernames: [String]
        let rotatingWarning: String?
    }

    enum ServiceError: LocalizedError {
        case invalidRequest
        case invalidResponse
        case api(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return L10n.text("feed.x.invalid_request")
            case .invalidResponse:
                return L10n.text("feed.x.invalid_response")
            case .api(let status, let message):
                return L10n.format("feed.x.api_error", status, message)
            }
        }
    }

    func fetch(
        bearerToken: String,
        accounts: [AIFeedAccount],
        tier: AIFeedTier,
        startTime: Date,
        maxResults: Int = AIFeedCollectionPolicy.maxPrimaryPostsPerDay
    ) async throws -> [AIFeedPost] {
        let url = try Self.searchURL(
            accounts: accounts,
            startTime: startTime,
            maxResults: maxResults
        )

        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIProblem.self, from: data).detail)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ServiceError.api(status: http.statusCode, message: message)
        }
        return try Self.decode(data: data, tier: tier)
    }

    func fetchTiered(
        bearerToken: String,
        primaryAccounts: [AIFeedAccount],
        rotatingCandidates: [AIFeedAccount],
        startTime: Date
    ) async throws -> TieredResult {
        let primaryPosts = try await fetch(
            bearerToken: bearerToken,
            accounts: primaryAccounts,
            tier: .primary,
            startTime: startTime,
            maxResults: AIFeedCollectionPolicy.fetchResultsPerTier
        )

        do {
            let candidatePosts = try await fetch(
                bearerToken: bearerToken,
                accounts: rotatingCandidates,
                tier: .rotating,
                startTime: startTime,
                maxResults: AIFeedCollectionPolicy.fetchResultsPerTier
            )
            let selection = AIFeedCollectionPolicy.selectRotating(from: candidatePosts)
            return TieredResult(
                posts: primaryPosts + selection.posts,
                selectedRotatingUsernames: selection.usernames,
                rotatingWarning: nil
            )
        } catch {
            return TieredResult(
                posts: primaryPosts,
                selectedRotatingUsernames: [],
                rotatingWarning: L10n.format("feed.rotating_refresh_failed", error.localizedDescription)
            )
        }
    }

    static func searchURL(
        accounts: [AIFeedAccount],
        startTime: Date,
        maxResults: Int
    ) throws -> URL {
        var components = URLComponents(string: "https://api.x.com/2/tweets/search/recent")
        let accountQuery = accounts.map { "from:\($0.username)" }.joined(separator: " OR ")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "(\(accountQuery)) -is:retweet -is:reply"),
            URLQueryItem(name: "max_results", value: "\(min(100, max(10, maxResults)))"),
            URLQueryItem(name: "sort_order", value: "recency"),
            URLQueryItem(name: "start_time", value: iso8601String(from: startTime)),
            URLQueryItem(name: "tweet.fields", value: "author_id,created_at,public_metrics"),
            URLQueryItem(name: "expansions", value: "author_id"),
            URLQueryItem(name: "user.fields", value: "name,username")
        ]
        guard let url = components?.url else {
            throw ServiceError.invalidRequest
        }
        return url
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func decode(data: Data, tier: AIFeedTier = .primary) throws -> [AIFeedPost] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(value)"
            )
        }

        let payload = try decoder.decode(SearchResponse.self, from: data)
        let users = Dictionary(
            uniqueKeysWithValues: (payload.includes?.users ?? []).map { ($0.id, $0) }
        )
        return AIFeedPost.sortedForDisplay((payload.data ?? []).compactMap { post in
            guard let author = users[post.authorID] else { return nil }
            return AIFeedPost(
                id: post.id,
                text: post.text,
                username: author.username,
                displayName: author.name,
                createdAt: post.createdAt,
                metrics: AIFeedMetrics(
                    likes: post.publicMetrics?.likeCount ?? 0,
                    reposts: post.publicMetrics?.retweetCount ?? 0,
                    replies: post.publicMetrics?.replyCount ?? 0
                ),
                priority: FeedPriorityClassifier.classify(post.text),
                externalURL: nil,
                tier: tier
            )
        })
    }
}

private struct SearchResponse: Decodable {
    let data: [RawPost]?
    let includes: Includes?
}

private struct RawPost: Decodable {
    let id: String
    let text: String
    let authorID: String
    let createdAt: Date
    let publicMetrics: RawMetrics?

    enum CodingKeys: String, CodingKey {
        case id, text
        case authorID = "author_id"
        case createdAt = "created_at"
        case publicMetrics = "public_metrics"
    }
}

private struct RawMetrics: Decodable {
    let likeCount: Int
    let retweetCount: Int
    let replyCount: Int

    enum CodingKeys: String, CodingKey {
        case likeCount = "like_count"
        case retweetCount = "retweet_count"
        case replyCount = "reply_count"
    }
}

private struct Includes: Decodable {
    let users: [RawUser]?
}

private struct RawUser: Decodable {
    let id: String
    let name: String
    let username: String
}

private struct APIProblem: Decodable {
    let detail: String?
}
