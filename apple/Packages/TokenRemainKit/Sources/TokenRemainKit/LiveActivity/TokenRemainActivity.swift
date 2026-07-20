import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

public struct TokenRemainActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public let minRemainingPercent: Double
        public let providers: [ProviderLine]
        public let soonestReset: Date?
        public let willLastUntilReset: Bool
        public let runOutAt: Date?
        public let generatedAt: Date
        public let isDemo: Bool

        public struct ProviderLine: Codable, Hashable, Sendable, Identifiable {
            public let id: String
            public let name: String
            public let remainingPercent: Double
            /// Provider identity travels as an enum, not a colour — the renderer owns the palette.
            public let provider: ProviderQuota.Provider

            public init(id: String, name: String, remainingPercent: Double, provider: ProviderQuota.Provider) {
                self.id = id
                self.name = name
                self.remainingPercent = remainingPercent
                self.provider = provider
            }
        }

        public init(
            minRemainingPercent: Double,
            providers: [ProviderLine],
            soonestReset: Date?,
            willLastUntilReset: Bool,
            runOutAt: Date?,
            generatedAt: Date,
            isDemo: Bool
        ) {
            self.minRemainingPercent = minRemainingPercent
            self.providers = providers
            self.soonestReset = soonestReset
            self.willLastUntilReset = willLastUntilReset
            self.runOutAt = runOutAt
            self.generatedAt = generatedAt
            self.isDemo = isDemo
        }

        public init(entry: TREntry) {
            self.init(
                minRemainingPercent: entry.minRemainingPercent ?? 0,
                providers: entry.providers.map {
                    ProviderLine(
                        id: $0.id,
                        name: $0.displayName,
                        remainingPercent: $0.remainingPercent,
                        provider: $0.provider
                    )
                },
                soonestReset: entry.soonestReset,
                willLastUntilReset: entry.willLastUntilReset,
                runOutAt: entry.runOutAt,
                generatedAt: entry.generatedAt,
                isDemo: entry.isDemo
            )
        }

        public var heroText: String {
            UsageFormatting.percent(minRemainingPercent.rounded())
        }
    }

    public let startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}

/// User-started, local-only Live Activity lifecycle. `pushType: nil` on purpose:
/// there is no push server in this build, so remote updates are never claimed.
@available(iOS 16.2, *)
public enum LiveActivityCoordinator {
    /// Past this the system dims the activity and the UI renders "数据未更新".
    public static let staleInterval: TimeInterval = 3_600

    public static var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    public static var isRunning: Bool {
        !Activity<TokenRemainActivityAttributes>.activities.isEmpty
    }

    @discardableResult
    public static func start(entry: TREntry, now: Date) -> Bool {
        guard areActivitiesEnabled, entry.hasNumbers else { return false }
        guard !isRunning else { return true }
        let content = ActivityContent(
            state: TokenRemainActivityAttributes.ContentState(entry: entry),
            staleDate: now.addingTimeInterval(staleInterval)
        )
        do {
            _ = try Activity.request(
                attributes: TokenRemainActivityAttributes(startedAt: now),
                content: content,
                pushType: nil
            )
            return true
        } catch {
            return false
        }
    }

    public static func update(entry: TREntry, now: Date) async {
        guard entry.hasNumbers else {
            await end(now: now)
            return
        }
        let content = ActivityContent(
            state: TokenRemainActivityAttributes.ContentState(entry: entry),
            staleDate: now.addingTimeInterval(staleInterval)
        )
        for activity in Activity<TokenRemainActivityAttributes>.activities {
            await activity.update(content)
        }
    }

    public static func end(now: Date) async {
        for activity in Activity<TokenRemainActivityAttributes>.activities {
            await activity.end(activity.content, dismissalPolicy: .immediate)
        }
    }
}
#endif
