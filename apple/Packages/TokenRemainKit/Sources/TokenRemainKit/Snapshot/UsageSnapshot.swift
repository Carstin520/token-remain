import Foundation

/// Where a snapshot's numbers came from. This is the product's core honesty mechanism:
/// no surface may render a percentage without an origin that justifies it.
public enum SnapshotOrigin: String, Codable, Sendable {
    /// Deterministic fixture, explicitly enabled by the user.
    case demo
    /// No source connected — surfaces render honest empty states.
    case none
    /// A verified, read-only snapshot received from the user's Mac.
    case macSync
}

/// The single serialization contract shared by the App Group, WatchConnectivity,
/// history and previews.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let macSyncStaleInterval: TimeInterval = 10 * 60
    public static let macSyncHardExpiry: TimeInterval = 24 * 60 * 60

    public let schemaVersion: Int
    public let origin: SnapshotOrigin
    public let generatedAt: Date
    public let providers: [ProviderQuota]
    /// Demo-only. Always nil for `.none` and `.macSync`.
    public let dailyTokens: [AgentTokens]?

    public init(
        schemaVersion: Int = UsageSnapshot.currentSchemaVersion,
        origin: SnapshotOrigin,
        generatedAt: Date,
        providers: [ProviderQuota],
        dailyTokens: [AgentTokens]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.origin = origin
        self.generatedAt = generatedAt
        self.providers = providers
        self.dailyTokens = dailyTokens
    }

    public var isDemo: Bool { origin == .demo }

    public func isMacSyncStale(at now: Date) -> Bool {
        origin == .macSync
            && now.timeIntervalSince(generatedAt) > Self.macSyncStaleInterval
    }

    public func isMacSyncExpired(at now: Date) -> Bool {
        origin == .macSync
            && now.timeIntervalSince(generatedAt) > Self.macSyncHardExpiry
    }

    /// True when the snapshot carries no renderable numbers.
    public var isEmpty: Bool { origin == .none || providers.isEmpty }

    public var insights: UsageInsights { UsageInsights(snapshot: self) }

    /// A snapshot with no numbers at all — the honest first-launch state.
    public static func empty(now: Date) -> UsageSnapshot {
        UsageSnapshot(origin: .none, generatedAt: now, providers: [], dailyTokens: nil)
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    /// Schema-version gated decode. Unknown version or corrupt payload ⇒ nil,
    /// which every caller treats as `.none` rather than crashing.
    public static func decoded(from data: Data) -> UsageSnapshot? {
        guard let snapshot = try? decoder.decode(UsageSnapshot.self, from: data) else { return nil }
        guard snapshot.schemaVersion == currentSchemaVersion else { return nil }
        return snapshot
    }
}
