import Foundation
import OSLog

/// Reads only the public, unauthenticated status endpoints published by OpenAI
/// and Claude. Requests carry no provider credentials or TokenRemain usage data.
struct ProviderStatusService: Sendable {
    private struct Endpoint: Sendable {
        let summaryURL: URL
        let statusPageURL: URL
    }

    private static let endpoints: [ProviderQuota.Provider: Endpoint] = [
        .codex: Endpoint(
            summaryURL: URL(string: "https://status.openai.com/api/v2/summary.json")!,
            statusPageURL: URL(string: "https://status.openai.com")!
        ),
        .claude: Endpoint(
            summaryURL: URL(string: "https://status.claude.com/api/v2/summary.json")!,
            statusPageURL: URL(string: "https://status.claude.com")!
        )
    ]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static let logger = Logger(
        subsystem: "com.jamesli.usagedock",
        category: "ProviderStatus"
    )

    func fetch(
        providers: [ProviderQuota.Provider],
        checkedAt: Date = .now
    ) async -> [ProviderQuota.Provider: ProviderServiceStatus] {
        await withTaskGroup(
            of: (ProviderQuota.Provider, ProviderServiceStatus)?.self
        ) { group in
            for provider in providers {
                guard let endpoint = Self.endpoints[provider] else { continue }
                group.addTask {
                    let status = await Self.fetch(
                        provider: provider,
                        endpoint: endpoint,
                        checkedAt: checkedAt
                    )
                    return (provider, status)
                }
            }

            var statuses: [ProviderQuota.Provider: ProviderServiceStatus] = [:]
            for await result in group {
                guard let (provider, status) = result else { continue }
                statuses[provider] = status
            }
            return statuses
        }
    }

    private static func fetch(
        provider: ProviderQuota.Provider,
        endpoint: Endpoint,
        checkedAt: Date
    ) async -> ProviderServiceStatus {
        do {
            var request = URLRequest(url: endpoint.summaryURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("TokenRemain/1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return try ProviderStatusParser.parse(
                data,
                provider: provider,
                checkedAt: checkedAt,
                statusPageURL: endpoint.statusPageURL
            )
        } catch {
            logger.error(
                "Official status check failed for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .unknown(
                provider: provider,
                checkedAt: checkedAt,
                statusPageURL: endpoint.statusPageURL
            )
        }
    }
}
