import Foundation

/// Public, credential-free entry point for the server-curated broadcast feed.
///
/// Production builds inject `TokenRemainBroadcastBaseURL` into Info.plist.
/// Local builds can instead set `TOKENREMAIN_BROADCAST_BASE_URL`.
enum FeedConfiguration {
    static let pollingIntervalSeconds: TimeInterval = 600
    private static let productionBaseURL =
        "https://tokenremain-broadcast.jamescarstin520.workers.dev"

    static var baseURL: URL? {
        let environmentValue = ProcessInfo.processInfo.environment[
            "TOKENREMAIN_BROADCAST_BASE_URL"
        ]
        let bundledValue = Bundle.main.object(
            forInfoDictionaryKey: "TokenRemainBroadcastBaseURL"
        ) as? String
        guard let rawValue = [environmentValue, bundledValue, productionBaseURL]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }),
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil
        else {
            return nil
        }
        return url
    }

    static var feedEndpoint: URL? {
        baseURL?.appending(path: "v1/ai-feed")
    }

    static var deviceRegistrationEndpoint: URL? {
        baseURL?.appending(path: "v1/devices/register")
    }

    static var sourceTitle: String {
        L10n.text("feed.source.curated")
    }
}
