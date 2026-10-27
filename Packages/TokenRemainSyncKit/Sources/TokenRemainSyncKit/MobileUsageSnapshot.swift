import CryptoKit
import Foundation

/// Stable provider identifiers understood by the current Apple clients. The
/// payload keeps provider IDs as strings so an older phone can still ignore a
/// provider added by a newer Mac without rejecting the authenticated snapshot.
public enum SyncedProviderID {
    public static let claude = "claude"
    public static let codex = "codex"
    public static let cursor = "cursor"
    public static let grok = "grok"
    public static let zai = "zai"
    public static let copilot = "copilot"
    public static let devin = "devin"
    public static let windsurf = "windsurf"
    public static let openrouter = "openrouter"
    public static let antigravity = "antigravity"
    public static let opencode = "opencode"
    public static let deepseek = "deepseek"
    public static let kimi = "kimi"
    public static let minimax = "minimax"
    public static let mimo = "mimo"
    public static let qoder = "qoder"
    public static let kiro = "kiro"
    public static let volcengine = "volcengine"
    public static let ollama = "ollama"

    /// A receiving client filters unknown IDs rather than treating them as a
    /// malformed payload. Senders must still use a stable, non-account-specific
    /// identifier that passes ``isWellFormed(_:)``.
    public static let canonicalMobileOrder: [String] = [
        claude, codex, cursor, grok, zai, copilot, devin, windsurf, openrouter,
        antigravity, opencode, deepseek, kimi, minimax, mimo, qoder,
        kiro, volcengine, ollama,
    ]
    public static let supportedOnCurrentMobile = Set(canonicalMobileOrder)

    /// A deliberately narrow wire format: lower-case ASCII product slugs only.
    /// It rejects account names, display strings, paths, and arbitrary provider
    /// response values from becoming identifiers by accident.
    public static func isWellFormed(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        guard let first = value.utf8.first,
              (first >= 97 && first <= 122) || (first >= 48 && first <= 57) else {
            return false
        }

        return value.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) ||
                byte == 45 || byte == 46 || byte == 95
        }
    }
}

/// Privacy-minimized source presentation shared by macOS and iPhone. The
/// protocol identity remains a random UUID, while UI and user-initiated
/// diagnostics expose only a short, non-hardware-derived correlation token.
public enum SyncSourcePresentation {
    public static let anonymousIDLength = 6

    public static func anonymousID(for sourceInstanceID: UUID) -> String {
        String(sourceInstanceID.uuidString.prefix(anonymousIDLength)).uppercased()
    }
}

/// A closed set of non-sensitive source states. It intentionally has no field
/// for a provider's raw error message, HTTP status, or diagnostic text.
public enum SyncedSourceStatus: String, Codable, Sendable, CaseIterable {
    case available
    case offline
    case expired
}

public struct SyncedQuotaBalance: Codable, Sendable, Equatable {
    public let amount: Double
    public let currencyCode: String

    public init(amount: Double, currencyCode: String) {
        self.amount = amount
        self.currencyCode = currencyCode
    }
}

public struct SyncedQuotaWindow: Codable, Sendable, Equatable {
    public static let maximumPoolNameUTF8Bytes = 48

    public let usedPercent: Double
    /// `0` represents a non-periodic pool; otherwise this is a positive window.
    public let windowMinutes: Int
    public let resetsAt: Date?
    public let remainingBalance: SyncedQuotaBalance?
    /// Some providers split one billing cycle into named pools that share a
    /// duration (Cursor's "Cursor Models" / "Other Models"). When the primary
    /// window is one such pool rather than the whole account, this names it so
    /// the phone can tell two same-duration values apart. Optional on the wire:
    /// synthesized Codable decodes a missing key as nil (the same
    /// `decodeIfPresent` behavior `remainingBalance` relies on), so payloads
    /// from older Macs keep decoding and `schemaVersion` stays at 1. A nil
    /// value is also omitted when encoding, so replay/payload digests of
    /// pool-less snapshots are byte-identical to pre-poolName builds.
    public let poolName: String?

    public init(
        usedPercent: Double,
        windowMinutes: Int,
        resetsAt: Date?,
        remainingBalance: SyncedQuotaBalance? = nil,
        poolName: String? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.remainingBalance = remainingBalance
        self.poolName = poolName
    }

    /// Same character policy as `SyncedProviderQuota.sanitizedPlanName` — the
    /// pool label crosses the encrypted device boundary, so account-like,
    /// path-like and control-character values never do — plus a tighter
    /// 48-byte cap matching the desktop model-scope display-name limit.
    /// Returns nil (drop the label, keep the window) rather than failing.
    public static func sanitizedPoolName(_ value: String?) -> String? {
        guard let sanitized = SyncedProviderQuota.sanitizedPlanName(value),
              sanitized.utf8.count <= maximumPoolNameUTF8Bytes else {
            return nil
        }
        return sanitized
    }
}

/// A named provider/model-specific limit kept outside the legacy `windows`
/// array so clients released before scoped limits existed can safely ignore it.
public struct SyncedScopedQuotaWindow: Codable, Sendable, Equatable {
    public let scopeID: String
    public let displayName: String
    public let window: SyncedQuotaWindow

    public init(scopeID: String, displayName: String, window: SyncedQuotaWindow) {
        self.scopeID = scopeID
        self.displayName = displayName
        self.window = window
    }
}

public struct SyncedProviderQuota: Codable, Sendable, Equatable {
    /// Stable product identifier, never an account name or provider display name.
    public let providerID: String
    public let windows: [SyncedQuotaWindow]
    public let capturedAt: Date
    public let statusCode: SyncedSourceStatus
    /// Optional presentation-only subscription tier. Provider credentials,
    /// account identifiers, URLs and arbitrary diagnostic strings are excluded.
    public let planName: String?
    public let scopedWindows: [SyncedScopedQuotaWindow]?

    public init(
        providerID: String,
        windows: [SyncedQuotaWindow],
        capturedAt: Date,
        statusCode: SyncedSourceStatus,
        planName: String? = nil,
        scopedWindows: [SyncedScopedQuotaWindow]? = nil
    ) {
        self.providerID = providerID
        self.windows = windows
        self.capturedAt = capturedAt
        self.statusCode = statusCode
        self.planName = planName
        self.scopedWindows = scopedWindows
    }

    /// Keeps a human-readable plan label while rejecting values that resemble
    /// accounts, paths or URLs. This is deliberately narrower than arbitrary UI
    /// text because this field crosses the encrypted device boundary.
    public static func sanitizedPlanName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else { return nil }
        guard !trimmed.contains("@"),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":") else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
            return nil
        }
        return trimmed
    }
}

/// Optional, opt-in aggregate usage. It is intentionally separate from quota
/// windows so the default snapshot has no token-volume or cost data at all.
public struct AggregateUsage: Codable, Sendable, Equatable {
    public let totalTokens: Int64
    public let periodStart: Date
    public let periodEnd: Date

    public init(totalTokens: Int64, periodStart: Date, periodEnd: Date) {
        self.totalTokens = totalTokens
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}

/// One privacy-minimized calendar-day aggregate from Mac `ccusage` history.
/// The day is a timezone-independent `yyyy-MM-dd` key; no session, project,
/// prompt, account, or file-path detail is permitted on this boundary. Product
/// identifiers — local-usage agent slugs and model names — may cross it in the
/// optional detail fields, which carry only token counts, estimated cost and
/// measured output speed.
public struct SyncedDailyUsageDay: Codable, Sendable, Equatable, Identifiable {
    public static let maximumAgents = 16

    public let day: String
    /// Fixed legacy columns, still published for clients that predate
    /// `agents` (iPhone 1.2, Windows).
    public let claudeTokens: Int64
    public let claudeCost: Double
    public let codexTokens: Int64
    public let codexCost: Double
    /// Every local-usage agent the Mac counted that day. Nil from Macs before
    /// 1.4.6 and on days the sender trimmed to fit the payload budget.
    public let agents: [SyncedAgentUsage]?
    /// The day's token kinds across every agent. Kept on days whose model
    /// rows were trimmed, so a range's token mix survives the budget.
    public let mix: SyncedTokenMix?

    public var id: String { day }

    public init(
        day: String,
        claudeTokens: Int64,
        claudeCost: Double,
        codexTokens: Int64,
        codexCost: Double,
        agents: [SyncedAgentUsage]? = nil,
        mix: SyncedTokenMix? = nil
    ) {
        self.day = day
        self.claudeTokens = claudeTokens
        self.claudeCost = claudeCost
        self.codexTokens = codexTokens
        self.codexCost = codexCost
        self.agents = agents
        self.mix = mix
    }

    /// The same day without its optional detail — what an older Mac sends.
    public var withoutDetail: SyncedDailyUsageDay {
        SyncedDailyUsageDay(
            day: day,
            claudeTokens: claudeTokens,
            claudeCost: claudeCost,
            codexTokens: codexTokens,
            codexCost: codexCost
        )
    }

    /// Every agent when the day carries them, otherwise the legacy columns.
    public var totalTokens: Int64 {
        guard let agents else { return claudeTokens + codexTokens }
        return agents.reduce(0) { $0 + $1.tokens }
    }

    public var totalCost: Double {
        guard let agents else { return claudeCost + codexCost }
        return agents.reduce(0) { $0 + $1.cost }
    }
}

/// One local-usage agent's share of a synced day.
public struct SyncedAgentUsage: Codable, Sendable, Equatable, Identifiable {
    public static let maximumModels = 8

    /// The Mac's local-usage source slug (`claude`, `codex`, `opencode`, …),
    /// a product identifier that passes `SyncedProviderID.isWellFormed`.
    public let id: String
    public let tokens: Int64
    public let cost: Double
    /// Bounded per-model rows, the tail folded into `SyncedModelUsage.otherID`.
    /// Only the most recent days that fit the payload budget carry them.
    public let models: [SyncedModelUsage]?

    public init(id: String, tokens: Int64, cost: Double, models: [SyncedModelUsage]? = nil) {
        self.id = id
        self.tokens = tokens
        self.cost = cost
        self.models = models
    }

    public var withoutModels: SyncedAgentUsage {
        SyncedAgentUsage(id: id, tokens: tokens, cost: cost)
    }

    /// Folds rows beyond `maximumModels` into one `other` row: the busiest
    /// named models stay, ties broken by identifier so every sender and
    /// merger produces the same list.
    public static func boundedModels(_ rows: [SyncedModelUsage]) -> [SyncedModelUsage] {
        var byID: [String: SyncedModelUsage] = [:]
        for row in rows {
            byID[row.id] = byID[row.id].map { $0.adding(row) } ?? row
        }
        let other = byID.removeValue(forKey: SyncedModelUsage.otherID)
        let named = byID.values.sorted {
            $0.totalTokens == $1.totalTokens ? $0.id < $1.id : $0.totalTokens > $1.totalTokens
        }
        guard named.count + (other == nil ? 0 : 1) > maximumModels else {
            return named + [other].compactMap { $0 }
        }
        let kept = Array(named.prefix(maximumModels - 1))
        let tail = Array(named.dropFirst(maximumModels - 1)) + [other].compactMap { $0 }
        let folded = tail.dropFirst().reduce(tail[0].foldedIntoOther) {
            $0.adding($1.foldedIntoOther)
        }
        return kept + [folded]
    }
}

/// One model's use by one agent on one day.
public struct SyncedModelUsage: Codable, Sendable, Equatable, Identifiable {
    /// The row that sums every model beyond the named ones.
    public static let otherID = "other"
    public static let maximumConstituents = 10_000

    public let id: String
    public let mix: SyncedTokenMix
    public let cost: Double
    /// Concrete models folded into the `other` row; nil for a named model.
    public let count: Int?
    /// Measured output speed inputs; nil without timed responses.
    public let speed: SyncedThroughput?

    public init(
        id: String,
        mix: SyncedTokenMix,
        cost: Double,
        count: Int? = nil,
        speed: SyncedThroughput? = nil
    ) {
        self.id = id
        self.mix = mix
        self.cost = cost
        self.count = count
        self.speed = speed
    }

    public var totalTokens: Int64 { mix.total }

    /// The row as part of `other`, which never shows a speed.
    public var foldedIntoOther: SyncedModelUsage {
        SyncedModelUsage(id: Self.otherID, mix: mix, cost: cost, count: count ?? 1)
    }

    /// Sums two rows for the same model. `other` rows add their constituent
    /// counts; named rows add their speed inputs.
    public func adding(_ other: SyncedModelUsage) -> SyncedModelUsage {
        let isOther = id == Self.otherID
        let speed: SyncedThroughput? = switch (self.speed, other.speed) {
        case let (lhs?, rhs?): lhs.adding(rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
        let cost = self.cost + other.cost
        return SyncedModelUsage(
            id: id,
            mix: mix.adding(other.mix),
            cost: cost.isFinite
                ? min(cost, SyncedDailyUsageHistory.maximumCostPerProviderPerDay)
                : SyncedDailyUsageHistory.maximumCostPerProviderPerDay,
            count: isOther
                ? min((count ?? 1) + (other.count ?? 1), Self.maximumConstituents)
                : nil,
            speed: isOther ? nil : speed
        )
    }

    /// Lower-case model identifiers as the Mac stores them (`opus-4-5`,
    /// `gpt-5.3-codex`, `anthropic/claude-sonnet`). `@` is excluded so nothing
    /// address-shaped passes; senders rewrite Vertex-style `name@date` to
    /// `name-date` and fold anything else into `other`.
    public static func isWellFormedID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count),
              let first = value.utf8.first,
              (first >= 97 && first <= 122) || (first >= 48 && first <= 57) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                || byte == 45 || byte == 46 || byte == 95 || byte == 47 || byte == 58
        }
    }
}

/// Token kinds in a fixed order, encoded as a five-number array
/// `[input, output, cacheWrite, cacheRead, cacheUnsplit]`: a day can carry
/// dozens of these and the whole snapshot must fit the 20 KiB envelope.
/// `cacheUnsplit` holds cache tokens from rows that predate the write/read split.
public struct SyncedTokenMix: Codable, Sendable, Equatable {
    public let input: Int64
    public let output: Int64
    public let cacheWrite: Int64
    public let cacheRead: Int64
    public let cacheUnsplit: Int64

    public static let zero = SyncedTokenMix(input: 0, output: 0, cacheWrite: 0, cacheRead: 0, cacheUnsplit: 0)

    public init(input: Int64, output: Int64, cacheWrite: Int64, cacheRead: Int64, cacheUnsplit: Int64) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.cacheUnsplit = cacheUnsplit
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        input = try container.decode(Int64.self)
        output = try container.decode(Int64.self)
        cacheWrite = try container.decode(Int64.self)
        cacheRead = try container.decode(Int64.self)
        cacheUnsplit = try container.decode(Int64.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A token mix has exactly five kinds"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(input)
        try container.encode(output)
        try container.encode(cacheWrite)
        try container.encode(cacheRead)
        try container.encode(cacheUnsplit)
    }

    public var values: [Int64] { [input, output, cacheWrite, cacheRead, cacheUnsplit] }

    /// Saturating sum, so merged detail never overflows its bound.
    public var total: Int64 {
        values.reduce(0) { SyncedDailyUsageHistory.saturatingAdd($0, $1) }
    }

    public func adding(_ other: SyncedTokenMix) -> SyncedTokenMix {
        typealias H = SyncedDailyUsageHistory
        return SyncedTokenMix(
            input: H.saturatingAdd(input, other.input),
            output: H.saturatingAdd(output, other.output),
            cacheWrite: H.saturatingAdd(cacheWrite, other.cacheWrite),
            cacheRead: H.saturatingAdd(cacheRead, other.cacheRead),
            cacheUnsplit: H.saturatingAdd(cacheUnsplit, other.cacheUnsplit)
        )
    }
}

/// End-to-end output speed inputs for one model on one day, encoded as
/// `[outputTokens, seconds, samples]`. Receivers derive tokens per second
/// (Σ output ÷ Σ seconds) themselves, so several Macs merge exactly.
public struct SyncedThroughput: Codable, Sendable, Equatable {
    /// The desktop's noise floor: fewer timed responses than this, or less
    /// time, is not shown as a speed.
    public static let minimumSamples = 3
    public static let minimumSeconds: Double = 5
    public static let maximumSeconds: Double = 30 * 24 * 60 * 60
    public static let maximumSamples = 10_000_000

    public let outputTokens: Int64
    public let seconds: Double
    public let samples: Int

    public init(outputTokens: Int64, seconds: Double, samples: Int) {
        self.outputTokens = outputTokens
        self.seconds = seconds
        self.samples = samples
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        outputTokens = try container.decode(Int64.self)
        seconds = try container.decode(Double.self)
        samples = try container.decode(Int.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A throughput sample has exactly three values"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(outputTokens)
        try container.encode(seconds)
        try container.encode(samples)
    }

    /// Nil below the noise floor.
    public var tokensPerSecond: Double? {
        guard samples >= Self.minimumSamples,
              seconds >= Self.minimumSeconds,
              outputTokens > 0 else { return nil }
        return Double(outputTokens) / seconds
    }

    public func adding(_ other: SyncedThroughput) -> SyncedThroughput {
        SyncedThroughput(
            outputTokens: SyncedDailyUsageHistory.saturatingAdd(outputTokens, other.outputTokens),
            seconds: min(seconds + other.seconds, Self.maximumSeconds),
            samples: min(samples + other.samples, Self.maximumSamples)
        )
    }
}

/// Optional history has a deliberately small retention window and fixed
/// provider columns. It is enabled independently on Mac because token volume
/// and estimated spend are more sensitive than remaining-percent snapshots.
public struct SyncedDailyUsageHistory: Codable, Sendable, Equatable {
    public static let maximumDays = 30
    public static let maximumTokensPerProviderPerDay: Int64 = 1_000_000_000_000_000
    public static let maximumCostPerProviderPerDay = 1_000_000.0

    public let days: [SyncedDailyUsageDay]
    public let capturedAt: Date
    /// The wire day key that represents "today" in the publishing Mac's
    /// calendar. Older snapshots omit it and remain decodable.
    public let sourceDay: String?

    public init(
        days: [SyncedDailyUsageDay],
        capturedAt: Date,
        sourceDay: String? = nil
    ) {
        self.days = days
        self.capturedAt = capturedAt
        self.sourceDay = sourceDay
    }

    /// Clamps at the per-day token bound instead of overflowing.
    public static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { return maximumTokensPerProviderPerDay }
        return min(sum, maximumTokensPerProviderPerDay)
    }
}

/// Legacy public-feed DTO retained for decoding snapshots from older Mac builds.
/// Current clients fetch the owner-managed public broadcast API directly and
/// current Mac publishers always encode `curatedFeed` as nil.
public struct SyncedCuratedPost: Codable, Sendable, Equatable, Identifiable {
    public enum Priority: String, Codable, Sendable, Equatable {
        case tokenReset
        case majorUpdate
        case normal
    }

    public let id: String
    public let username: String
    public let displayName: String
    public let text: String
    public let createdAt: Date
    public let url: URL
    public let priority: Priority

    public init(
        id: String,
        username: String,
        displayName: String,
        text: String,
        createdAt: Date,
        url: URL,
        priority: Priority
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.text = text
        self.createdAt = createdAt
        self.url = url
        self.priority = priority
    }
}

/// Backward-compatible container for older encrypted snapshots. It is no longer
/// a live transport path for the product broadcast feed.
public struct SyncedCuratedFeed: Codable, Sendable, Equatable {
    public static let maximumPosts = 3
    public static let maximumPostAge: TimeInterval = 14 * 24 * 60 * 60

    public let posts: [SyncedCuratedPost]
    public let capturedAt: Date

    public init(posts: [SyncedCuratedPost], capturedAt: Date) {
        self.posts = posts
        self.capturedAt = capturedAt
    }
}

/// A cross-device DTO. Do not substitute `UsageSnapshot`, `ProviderQuota`, or a
/// macOS provider model here: those models contain presentation and account
/// details outside the mobile sync allowlist.
public struct MobileUsageSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sourceInstanceID: UUID
    public let sequence: UInt64
    public let generatedAt: Date
    public let expiresAt: Date
    public let providers: [SyncedProviderQuota]
    public let aggregateUsage: AggregateUsage?
    public let dailyUsageHistory: SyncedDailyUsageHistory?
    public let curatedFeed: SyncedCuratedFeed?

    public init(
        schemaVersion: Int = MobileUsageSnapshot.currentSchemaVersion,
        sourceInstanceID: UUID,
        sequence: UInt64,
        generatedAt: Date,
        expiresAt: Date,
        providers: [SyncedProviderQuota],
        aggregateUsage: AggregateUsage? = nil,
        dailyUsageHistory: SyncedDailyUsageHistory? = nil,
        curatedFeed: SyncedCuratedFeed? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceInstanceID = sourceInstanceID
        self.sequence = sequence
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.providers = providers
        self.aggregateUsage = aggregateUsage
        self.dailyUsageHistory = dailyUsageHistory
        self.curatedFeed = curatedFeed
    }

    /// Validates a snapshot before a source encrypts it. Every provider must be
    /// valid, but the source is not restricted to the current phone's provider
    /// catalog: newer providers are allowed on the wire.
    public func validatedForTransport(
        configuration: SyncValidationConfiguration = .current()
    ) throws -> MobileUsageSnapshot {
        try validateCore(configuration: configuration)

        var providerIDs = Set<String>()
        for provider in providers {
            guard providerIDs.insert(provider.providerID).inserted else {
                throw SyncValidationError.duplicateProviderID(provider.providerID)
            }
            try validate(provider: provider, configuration: configuration)
        }
        return self
    }

    /// Validates a received snapshot and filters providers that this client does
    /// not understand or that fail their provider-local validation. Top-level
    /// invariants remain strict, so a bad schema, expired snapshot, invalid
    /// timing, or malformed optional aggregate never replaces a good local value.
    public func validatedForConsumption(
        supportedProviderIDs: Set<String> = SyncedProviderID.supportedOnCurrentMobile,
        configuration: SyncValidationConfiguration = .current()
    ) throws -> MobileUsageSnapshot {
        try validateCore(configuration: configuration)

        var includedIDs = Set<String>()
        var includedProviders: [SyncedProviderQuota] = []
        includedProviders.reserveCapacity(providers.count)

        for provider in providers {
            guard supportedProviderIDs.contains(provider.providerID),
                  includedIDs.insert(provider.providerID).inserted else {
                continue
            }
            guard (try? validate(provider: provider, configuration: configuration)) != nil else {
                continue
            }
            includedProviders.append(provider)
        }

        return MobileUsageSnapshot(
            schemaVersion: schemaVersion,
            sourceInstanceID: sourceInstanceID,
            sequence: sequence,
            generatedAt: generatedAt,
            expiresAt: expiresAt,
            providers: includedProviders,
            aggregateUsage: aggregateUsage,
            dailyUsageHistory: dailyUsageHistory,
            curatedFeed: curatedFeed
        )
    }

    /// Stable JSON used only as the encrypted payload. Never write this to logs.
    public func encodedPayload() throws -> Data {
        try SyncPayloadCodec.encode(self)
    }

    public static func decodedPayload(from data: Data) throws -> MobileUsageSnapshot {
        try SyncPayloadCodec.decode(MobileUsageSnapshot.self, from: data)
    }

    func normalizedForWire() throws -> MobileUsageSnapshot {
        MobileUsageSnapshot(
            schemaVersion: schemaVersion,
            sourceInstanceID: sourceInstanceID,
            sequence: sequence,
            generatedAt: try SyncTimestamp.normalized(generatedAt),
            expiresAt: try SyncTimestamp.normalized(expiresAt),
            providers: try providers.map { provider in
                SyncedProviderQuota(
                    providerID: provider.providerID,
                    windows: try provider.windows.map {
                        SyncedQuotaWindow(
                            usedPercent: $0.usedPercent,
                            windowMinutes: $0.windowMinutes,
                            resetsAt: try $0.resetsAt.map(SyncTimestamp.normalized),
                            remainingBalance: $0.remainingBalance,
                            poolName: $0.poolName
                        )
                    },
                    capturedAt: try SyncTimestamp.normalized(provider.capturedAt),
                    statusCode: provider.statusCode,
                    planName: provider.planName,
                    scopedWindows: try provider.scopedWindows?.map { scoped in
                        SyncedScopedQuotaWindow(
                            scopeID: scoped.scopeID,
                            displayName: scoped.displayName,
                            window: SyncedQuotaWindow(
                                usedPercent: scoped.window.usedPercent,
                                windowMinutes: scoped.window.windowMinutes,
                                resetsAt: try scoped.window.resetsAt.map(SyncTimestamp.normalized),
                                remainingBalance: scoped.window.remainingBalance,
                                poolName: scoped.window.poolName
                            )
                        )
                    }
                )
            },
            aggregateUsage: try aggregateUsage.map {
                AggregateUsage(
                    totalTokens: $0.totalTokens,
                    periodStart: try SyncTimestamp.normalized($0.periodStart),
                    periodEnd: try SyncTimestamp.normalized($0.periodEnd)
                )
            },
            dailyUsageHistory: try dailyUsageHistory.map {
                SyncedDailyUsageHistory(
                    days: $0.days,
                    capturedAt: try SyncTimestamp.normalized($0.capturedAt),
                    sourceDay: $0.sourceDay
                )
            },
            curatedFeed: try curatedFeed.map {
                SyncedCuratedFeed(
                    posts: try $0.posts.map { post in
                        SyncedCuratedPost(
                            id: post.id,
                            username: post.username,
                            displayName: post.displayName,
                            text: post.text,
                            createdAt: try SyncTimestamp.normalized(post.createdAt),
                            url: post.url,
                            priority: post.priority
                        )
                    },
                    capturedAt: try SyncTimestamp.normalized($0.capturedAt)
                )
            }
        )
    }

    private func validateCore(configuration: SyncValidationConfiguration) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SyncValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard sourceInstanceID != .syncProtocolZero else {
            throw SyncValidationError.emptySourceInstanceID
        }
        guard sequence > 0 else {
            throw SyncValidationError.invalidSequence
        }

        try SyncTimestamp.validate(generatedAt, field: .generatedAt)
        try SyncTimestamp.validate(expiresAt, field: .expiresAt)

        guard generatedAt <= configuration.now.addingTimeInterval(configuration.maximumFutureSkew) else {
            throw SyncValidationError.dateTooFarInFuture(.generatedAt)
        }
        guard expiresAt > generatedAt else {
            throw SyncValidationError.expiresAtNotAfterGeneratedAt
        }
        guard expiresAt.timeIntervalSince(generatedAt) <= configuration.maximumSnapshotLifetime else {
            throw SyncValidationError.snapshotLifetimeTooLong
        }
        guard expiresAt >= configuration.now else {
            throw SyncValidationError.snapshotExpired
        }
        guard providers.count <= configuration.maximumProviderCount else {
            throw SyncValidationError.tooManyProviders
        }

        if let aggregateUsage {
            try validate(aggregateUsage: aggregateUsage, configuration: configuration)
        }
        if let dailyUsageHistory {
            try validate(dailyUsageHistory: dailyUsageHistory, configuration: configuration)
        }
        if let curatedFeed {
            try validate(curatedFeed: curatedFeed, configuration: configuration)
        }
    }

    private func validate(
        provider: SyncedProviderQuota,
        configuration: SyncValidationConfiguration
    ) throws {
        guard SyncedProviderID.isWellFormed(provider.providerID) else {
            throw SyncValidationError.invalidProviderID(provider.providerID)
        }
        if let planName = provider.planName,
           SyncedProviderQuota.sanitizedPlanName(planName) != planName {
            throw SyncValidationError.invalidPlanName(provider.providerID)
        }
        try SyncTimestamp.validate(provider.capturedAt, field: .capturedAt)
        guard provider.capturedAt <= configuration.now.addingTimeInterval(configuration.maximumFutureSkew) else {
            throw SyncValidationError.dateTooFarInFuture(.capturedAt)
        }
        guard provider.windows.count + (provider.scopedWindows?.count ?? 0)
                <= configuration.maximumWindowsPerProvider else {
            throw SyncValidationError.tooManyWindows(provider.providerID)
        }

        var windowMinutes = Set<Int>()
        for window in provider.windows {
            guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else {
                throw SyncValidationError.invalidPercent(provider.providerID)
            }
            guard (0...configuration.maximumWindowMinutes).contains(window.windowMinutes) else {
                throw SyncValidationError.invalidWindowMinutes(provider.providerID)
            }
            guard windowMinutes.insert(window.windowMinutes).inserted else {
                throw SyncValidationError.duplicateWindow(provider.providerID, window.windowMinutes)
            }
            if let resetsAt = window.resetsAt {
                try SyncTimestamp.validate(resetsAt, field: .resetsAt)
            }
            try validate(balance: window.remainingBalance, providerID: provider.providerID)
            try validate(poolName: window.poolName, providerID: provider.providerID)
        }
        var scopeIDs = Set<String>()
        for scoped in provider.scopedWindows ?? [] {
            guard Self.isWellFormedScopeID(scoped.scopeID),
                  scopeIDs.insert(scoped.scopeID).inserted,
                  SyncedProviderQuota.sanitizedPlanName(scoped.displayName) == scoped.displayName else {
                throw SyncValidationError.invalidProviderID(provider.providerID)
            }
            let window = scoped.window
            guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else {
                throw SyncValidationError.invalidPercent(provider.providerID)
            }
            guard (0...configuration.maximumWindowMinutes).contains(window.windowMinutes) else {
                throw SyncValidationError.invalidWindowMinutes(provider.providerID)
            }
            if let resetsAt = window.resetsAt {
                try SyncTimestamp.validate(resetsAt, field: .resetsAt)
            }
            try validate(balance: window.remainingBalance, providerID: provider.providerID)
            try validate(poolName: window.poolName, providerID: provider.providerID)
        }
    }

    /// Nil is always valid (most windows are the whole account); a non-nil pool
    /// label must already be in sanitized form so nothing account- or path-like
    /// crosses the boundary. Senders sanitize-or-drop before packaging, so a
    /// failure here only rejects payloads that bypassed the redactor.
    private func validate(poolName: String?, providerID: String) throws {
        guard let poolName else { return }
        guard SyncedQuotaWindow.sanitizedPoolName(poolName) == poolName else {
            throw SyncValidationError.invalidPoolName(providerID)
        }
    }

    private func validate(balance: SyncedQuotaBalance?, providerID: String) throws {
        guard let balance else { return }
        let code = balance.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard balance.amount.isFinite,
              balance.amount >= 0,
              code == balance.currencyCode,
              code.utf8.count <= 12,
              code.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) ||
                      (byte >= 65 && byte <= 90) ||
                      (byte >= 97 && byte <= 122)
              }) else {
            throw SyncValidationError.invalidBalance(providerID)
        }
    }

    private static func isWellFormedScopeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.unicodeScalars.allSatisfy {
            CharacterSet.lowercaseLetters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || $0 == "_"
                || $0 == "-"
        }
    }

    private func validate(
        aggregateUsage: AggregateUsage,
        configuration: SyncValidationConfiguration
    ) throws {
        guard aggregateUsage.totalTokens >= 0 else {
            throw SyncValidationError.invalidAggregateUsage
        }
        try SyncTimestamp.validate(aggregateUsage.periodStart, field: .aggregatePeriodStart)
        try SyncTimestamp.validate(aggregateUsage.periodEnd, field: .aggregatePeriodEnd)
        guard aggregateUsage.periodEnd > aggregateUsage.periodStart,
              aggregateUsage.periodEnd <= configuration.now.addingTimeInterval(configuration.maximumFutureSkew),
              aggregateUsage.periodEnd.timeIntervalSince(aggregateUsage.periodStart) <= configuration.maximumAggregatePeriod else {
            throw SyncValidationError.invalidAggregateUsage
        }
    }

    private func validate(
        dailyUsageHistory: SyncedDailyUsageHistory,
        configuration: SyncValidationConfiguration
    ) throws {
        guard dailyUsageHistory.days.count <= SyncedDailyUsageHistory.maximumDays else {
            throw SyncValidationError.invalidDailyUsageHistory
        }
        try SyncTimestamp.validate(dailyUsageHistory.capturedAt, field: .historyCapturedAt)
        guard dailyUsageHistory.capturedAt <= configuration.now.addingTimeInterval(configuration.maximumFutureSkew) else {
            throw SyncValidationError.dateTooFarInFuture(.historyCapturedAt)
        }

        var previousDay: String?
        let earliest = SyncDayKey.dayOffset(-SyncedDailyUsageHistory.maximumDays, from: configuration.now)
        let latest = SyncDayKey.dayOffset(1, from: configuration.now)
        if let sourceDay = dailyUsageHistory.sourceDay {
            guard SyncDayKey.date(from: sourceDay) != nil,
                  sourceDay >= earliest,
                  sourceDay <= latest else {
                throw SyncValidationError.invalidDailyUsageHistory
            }
        }
        for day in dailyUsageHistory.days {
            guard SyncDayKey.date(from: day.day) != nil,
                  day.day >= earliest,
                  day.day <= latest,
                  previousDay.map({ $0 < day.day }) ?? true,
                  Self.valid(tokens: day.claudeTokens),
                  Self.valid(tokens: day.codexTokens),
                  Self.valid(cost: day.claudeCost),
                  Self.valid(cost: day.codexCost),
                  Self.validDetail(of: day) else {
                throw SyncValidationError.invalidDailyUsageHistory
            }
            previousDay = day.day
        }
    }

    /// Optional per-agent and per-model detail. Every count is bounded and
    /// every identifier is a product slug, so nothing account- or path-like
    /// and no unbounded list can ride on a valid day.
    private static func validDetail(of day: SyncedDailyUsageDay) -> Bool {
        if let mix = day.mix, !valid(mix: mix) { return false }
        guard let agents = day.agents else { return true }
        guard agents.count <= SyncedDailyUsageDay.maximumAgents else { return false }
        var agentIDs = Set<String>()
        for agent in agents {
            guard SyncedProviderID.isWellFormed(agent.id),
                  agentIDs.insert(agent.id).inserted,
                  valid(tokens: agent.tokens),
                  valid(cost: agent.cost) else {
                return false
            }
            guard let models = agent.models else { continue }
            guard models.count <= SyncedAgentUsage.maximumModels else { return false }
            var modelIDs = Set<String>()
            for model in models {
                guard SyncedModelUsage.isWellFormedID(model.id),
                      modelIDs.insert(model.id).inserted,
                      valid(mix: model.mix),
                      valid(cost: model.cost),
                      model.count.map({ (1...SyncedModelUsage.maximumConstituents).contains($0) }) ?? true,
                      model.speed.map(valid(speed:)) ?? true else {
                    return false
                }
            }
        }
        return true
    }

    private static func valid(mix: SyncedTokenMix) -> Bool {
        mix.values.allSatisfy(valid(tokens:))
    }

    private static func valid(speed: SyncedThroughput) -> Bool {
        valid(tokens: speed.outputTokens)
            && speed.seconds.isFinite
            && (0...SyncedThroughput.maximumSeconds).contains(speed.seconds)
            && (0...SyncedThroughput.maximumSamples).contains(speed.samples)
    }

    private func validate(
        curatedFeed: SyncedCuratedFeed,
        configuration: SyncValidationConfiguration
    ) throws {
        guard curatedFeed.posts.count <= SyncedCuratedFeed.maximumPosts else {
            throw SyncValidationError.invalidCuratedFeed
        }
        try SyncTimestamp.validate(curatedFeed.capturedAt, field: .feedCapturedAt)
        guard curatedFeed.capturedAt <= configuration.now.addingTimeInterval(configuration.maximumFutureSkew) else {
            throw SyncValidationError.dateTooFarInFuture(.feedCapturedAt)
        }

        var ids = Set<String>()
        for post in curatedFeed.posts {
            guard ids.insert(post.id).inserted,
                  (1...64).contains(post.id.utf8.count),
                  post.id.utf8.allSatisfy({ (48...57).contains($0) }),
                  Self.isValidXUsername(post.username),
                  Self.isBoundedPublicText(post.displayName, maximumUTF8Bytes: 160),
                  Self.isBoundedPublicText(post.text, maximumUTF8Bytes: 2_000),
                  post.url.absoluteString.utf8.count <= 512,
                  Self.isCanonicalXStatusURL(post.url, username: post.username, id: post.id) else {
                throw SyncValidationError.invalidCuratedFeed
            }
            try SyncTimestamp.validate(post.createdAt, field: .feedPostCreatedAt)
            guard post.createdAt <= configuration.now.addingTimeInterval(configuration.maximumFutureSkew),
                  post.createdAt >= configuration.now.addingTimeInterval(-SyncedCuratedFeed.maximumPostAge) else {
                throw SyncValidationError.invalidCuratedFeed
            }
        }
    }

    private static func isValidXUsername(_ value: String) -> Bool {
        guard (1...15).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) ||
                byte == 95
        }
    }

    private static func isBoundedPublicText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || scalar.value >= 32
        }
    }

    private static func isCanonicalXStatusURL(_ url: URL, username: String, id: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              ["x.com", "www.x.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil else { return false }
        let expected = "/\(username)/status/\(id)"
        return url.path.caseInsensitiveCompare(expected) == .orderedSame
    }

    private static func valid(tokens: Int64) -> Bool {
        (0...SyncedDailyUsageHistory.maximumTokensPerProviderPerDay).contains(tokens)
    }

    private static func valid(cost: Double) -> Bool {
        cost.isFinite && (0...SyncedDailyUsageHistory.maximumCostPerProviderPerDay).contains(cost)
    }
}

private enum SyncDayKey {
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    static func date(from value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return date
    }

    static func dayOffset(_ offset: Int, from date: Date) -> String {
        let start = calendar.startOfDay(for: date)
        let shifted = calendar.date(byAdding: .day, value: offset, to: start) ?? start
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

public struct SyncValidationConfiguration: Sendable, Equatable {
    public let now: Date
    public let maximumFutureSkew: TimeInterval
    public let maximumSnapshotLifetime: TimeInterval
    public let maximumProviderCount: Int
    public let maximumWindowsPerProvider: Int
    public let maximumWindowMinutes: Int
    public let maximumAggregatePeriod: TimeInterval

    public init(
        now: Date,
        maximumFutureSkew: TimeInterval = 5 * 60,
        maximumSnapshotLifetime: TimeInterval = 24 * 60 * 60,
        maximumProviderCount: Int = 32,
        maximumWindowsPerProvider: Int = 8,
        maximumWindowMinutes: Int = 525_600,
        maximumAggregatePeriod: TimeInterval = 8 * 24 * 60 * 60
    ) {
        self.now = now
        self.maximumFutureSkew = maximumFutureSkew
        self.maximumSnapshotLifetime = maximumSnapshotLifetime
        self.maximumProviderCount = maximumProviderCount
        self.maximumWindowsPerProvider = maximumWindowsPerProvider
        self.maximumWindowMinutes = maximumWindowMinutes
        self.maximumAggregatePeriod = maximumAggregatePeriod
    }

    public static func current(now: Date = Date()) -> SyncValidationConfiguration {
        SyncValidationConfiguration(now: now)
    }
}

public enum SyncDateField: Sendable, Equatable {
    case generatedAt
    case expiresAt
    case capturedAt
    case resetsAt
    case aggregatePeriodStart
    case aggregatePeriodEnd
    case historyCapturedAt
    case feedCapturedAt
    case feedPostCreatedAt
}

public enum SyncValidationError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case emptySourceInstanceID
    case invalidSequence
    case invalidDate(SyncDateField)
    case dateTooFarInFuture(SyncDateField)
    case expiresAtNotAfterGeneratedAt
    case snapshotLifetimeTooLong
    case snapshotExpired
    case tooManyProviders
    case invalidProviderID(String)
    case invalidPlanName(String)
    case duplicateProviderID(String)
    case tooManyWindows(String)
    case duplicateWindow(String, Int)
    case invalidPercent(String)
    case invalidWindowMinutes(String)
    case invalidBalance(String)
    case invalidPoolName(String)
    case invalidAggregateUsage
    case invalidDailyUsageHistory
    case invalidCuratedFeed
}

public struct SyncReplayMarker: Codable, Sendable, Equatable {
    public let sourceInstanceID: UUID
    public let sequence: UInt64
    public let generatedAt: Date
    /// SHA-256 of the normalized authenticated snapshot. Older persisted replay
    /// markers decode with nil and retain timestamp-only duplicate semantics
    /// until a higher sequence is accepted.
    public let payloadDigest: String?

    public init(
        sourceInstanceID: UUID,
        sequence: UInt64,
        generatedAt: Date,
        payloadDigest: String? = nil
    ) {
        self.sourceInstanceID = sourceInstanceID
        self.sequence = sequence
        self.generatedAt = generatedAt
        self.payloadDigest = payloadDigest
    }

    init(snapshot: MobileUsageSnapshot) throws {
        self.init(
            sourceInstanceID: snapshot.sourceInstanceID,
            sequence: snapshot.sequence,
            generatedAt: snapshot.generatedAt,
            payloadDigest: try SyncReplayFingerprint.digest(snapshot)
        )
    }
}

/// Per-source replay/LWW state for the v1.2 multi-Mac protocol. Unlike the
/// legacy single-source guard, a newly authenticated source is independent and
/// never replaces another Mac's marker.
public struct SyncReplayRegistry: Codable, Sendable, Equatable {
    public static let maximumSourceCount = 16

    private var markersBySource: [UUID: SyncReplayMarker]

    public init() {
        markersBySource = [:]
    }

    public init(validating markers: [SyncReplayMarker]) throws {
        guard markers.count <= Self.maximumSourceCount else {
            throw SyncReplayRegistryError.tooManySources
        }

        var storage: [UUID: SyncReplayMarker] = [:]
        for marker in markers {
            try Self.validate(marker)
            guard storage.updateValue(marker, forKey: marker.sourceInstanceID) == nil else {
                throw SyncReplayRegistryError.duplicateSource(marker.sourceInstanceID)
            }
        }
        markersBySource = storage
    }

    public var count: Int { markersBySource.count }

    public var markers: [SyncReplayMarker] {
        markersBySource.values.sorted {
            $0.sourceInstanceID.uuidString < $1.sourceInstanceID.uuidString
        }
    }

    public func marker(for sourceInstanceID: UUID) -> SyncReplayMarker? {
        markersBySource[sourceInstanceID]
    }

    @discardableResult
    public mutating func evaluate(
        _ snapshot: MobileUsageSnapshot,
        configuration: SyncValidationConfiguration = .current()
    ) throws -> SyncReplayDecision {
        let validated = try snapshot
            .validatedForConsumption(configuration: configuration)
            .normalizedForWire()
        let candidate = try SyncReplayMarker(snapshot: validated)

        guard let latest = markersBySource[candidate.sourceInstanceID] else {
            guard markersBySource.count < Self.maximumSourceCount else {
                throw SyncReplayRegistryError.tooManySources
            }
            markersBySource[candidate.sourceInstanceID] = candidate
            return .accepted
        }
        if candidate.sequence > latest.sequence {
            markersBySource[candidate.sourceInstanceID] = candidate
            return .accepted
        }
        if candidate.sequence < latest.sequence {
            return .replayedOlderSequence
        }
        guard candidate.generatedAt == latest.generatedAt else {
            return .conflictingSequence
        }
        if let candidateDigest = candidate.payloadDigest,
           let latestDigest = latest.payloadDigest,
           candidateDigest != latestDigest {
            return .conflictingSequence
        }
        return .duplicate
    }

    public mutating func remove(sourceInstanceID: UUID) {
        markersBySource.removeValue(forKey: sourceInstanceID)
    }

    public mutating func removeAll() {
        markersBySource.removeAll(keepingCapacity: false)
    }

    private enum CodingKeys: String, CodingKey {
        case markers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let markers = try container.decode([SyncReplayMarker].self, forKey: .markers)
        do {
            try self.init(validating: markers)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .markers,
                in: container,
                debugDescription: "Invalid per-source replay registry"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(markers, forKey: .markers)
    }

    private static func validate(_ marker: SyncReplayMarker) throws {
        guard marker.sourceInstanceID != .syncProtocolZero,
              marker.sequence > 0,
              marker.generatedAt.timeIntervalSince1970.isFinite else {
            throw SyncReplayRegistryError.invalidMarker(marker.sourceInstanceID)
        }
        if let digest = marker.payloadDigest {
            guard digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ byte in
                      (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
                  }) else {
                throw SyncReplayRegistryError.invalidMarker(marker.sourceInstanceID)
            }
        }
    }
}

public enum SyncReplayRegistryError: Error, Sendable, Equatable {
    case tooManySources
    case duplicateSource(UUID)
    case invalidMarker(UUID)
}

public enum SyncReplayDecision: Sendable, Equatable {
    case accepted
    case duplicate
    case replayedOlderSequence
    case conflictingSequence
}

private enum SyncReplayFingerprint {
    static func digest(_ snapshot: MobileUsageSnapshot) throws -> String {
        let data = try SyncPayloadCodec.encode(snapshot)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncPayloadCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

enum SyncTimestamp {
    static func validate(_ date: Date, field: SyncDateField) throws {
        guard date.timeIntervalSince1970.isFinite else {
            throw SyncValidationError.invalidDate(field)
        }
        _ = try milliseconds(date, field: field)
    }

    static func normalized(_ date: Date) throws -> Date {
        let milliseconds = try milliseconds(date, field: .generatedAt)
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    static func milliseconds(_ date: Date, field: SyncDateField) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= Double(Int64.min),
              value <= Double(Int64.max) else {
            throw SyncValidationError.invalidDate(field)
        }
        return Int64(value.rounded(.towardZero))
    }
}

private extension UUID {
    static let syncProtocolZero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
