import Foundation

/// Engineering entry point for AI Feed delivery.
///
/// Development:
///   Keep `.directXAPI`. Put the Bearer Token in
///   `Config/UsageDockFeed.local.plist`; the build script asks the signed app
///   to import it into its own Keychain item.
///
/// Productization:
///   Change `delivery` to `.curatedAPI(endpoint: ...)`. The client will then
///   consume only content selected by the UsageDock backend and never receive
///   an X API credential.
enum FeedConfiguration {
    static let delivery: FeedDelivery = .directXAPI

    // Productization example:
    // static let delivery: FeedDelivery = .curatedAPI(
    //     endpoint: URL(string: "https://api.usagedock.app/v1/ai-feed")!
    // )

    static let pollingIntervalSeconds: TimeInterval = 600
    static let primaryAccounts = AIFeedAccount.primary
    static let rotatingCandidates = AIFeedAccount.rotatingCandidates
}

enum FeedDelivery: Sendable {
    case directXAPI
    case curatedAPI(endpoint: URL)

    var requiresXBearerToken: Bool {
        if case .directXAPI = self { return true }
        return false
    }

    var sourceTitle: String {
        switch self {
        case .directXAPI: return "X 官方 API · 最近公开动态"
        case .curatedAPI: return "Token Remain 精选源 · 已审核内容"
        }
    }
}
