import Foundation

struct CuratedFeedService: Sendable {
    enum ServiceError: LocalizedError {
        case invalidResponse
        case api(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return L10n.text("feed.curated.invalid_response")
            case .api(let status, let message):
                return L10n.format("feed.curated.api_error", status, message)
            }
        }
    }

    let endpoint: URL

    func fetch() async throws -> [AIFeedPost] {
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(CuratedProblem.self, from: data).detail)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ServiceError.api(status: http.statusCode, message: detail)
        }
        return try Self.decode(data: data)
    }

    static func decode(data: Data) throws -> [AIFeedPost] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Self.decodeDate(decoder)
        }
        let payload = try decoder.decode(CuratedFeedPayload.self, from: data)

        return AIFeedPost.sortedForDisplay(payload.items.map { item in
            AIFeedPost(
                id: item.id,
                text: item.text,
                username: item.author.username,
                displayName: item.author.displayName,
                createdAt: item.publishedAt,
                metrics: item.metrics ?? .init(likes: 0, reposts: 0, replies: 0),
                priority: item.priority?.appPriority
                    ?? FeedPriorityClassifier.classify(item.text),
                externalURL: item.url,
                tier: item.tier?.appTier ?? AIFeedAccount.tier(for: item.author.username)
            )
        })
    }

    private static func decodeDate(_ decoder: Decoder) throws -> Date {
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
}

private struct CuratedFeedPayload: Decodable {
    let items: [CuratedFeedItem]
}

private struct CuratedFeedItem: Decodable {
    let id: String
    let text: String
    let author: CuratedFeedAuthor
    let publishedAt: Date
    let url: URL?
    let priority: CuratedPriority?
    let metrics: AIFeedMetrics?
    let tier: CuratedTier?
}

private struct CuratedFeedAuthor: Decodable {
    let username: String
    let displayName: String
}

private enum CuratedPriority: String, Decodable {
    case tokenReset = "token_reset"
    case majorUpdate = "major_update"
    case normal

    var appPriority: AIFeedPriority {
        switch self {
        case .tokenReset: return .tokenReset
        case .majorUpdate: return .majorUpdate
        case .normal: return .normal
        }
    }
}

private enum CuratedTier: String, Decodable {
    case primary
    case rotating

    var appTier: AIFeedTier {
        switch self {
        case .primary: return .primary
        case .rotating: return .rotating
        }
    }
}

private struct CuratedProblem: Decodable {
    let detail: String?
}
