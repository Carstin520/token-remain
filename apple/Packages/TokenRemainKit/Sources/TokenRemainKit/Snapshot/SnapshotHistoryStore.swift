import Foundation

public struct SnapshotHistoryPoint: Codable, Sendable, Equatable, Identifiable {
    public let generatedAt: Date
    public let minRemainingPercent: Double
    public let perProviderRemaining: [String: Double]
    public let isDemo: Bool

    public var id: Date { generatedAt }

    public init(
        generatedAt: Date,
        minRemainingPercent: Double,
        perProviderRemaining: [String: Double],
        isDemo: Bool
    ) {
        self.generatedAt = generatedAt
        self.minRemainingPercent = minRemainingPercent
        self.perProviderRemaining = perProviderRemaining
        self.isDemo = isDemo
    }

    public init?(snapshot: UsageSnapshot) {
        let insights = snapshot.insights
        guard let minRemaining = insights.minRemainingPercent else { return nil }
        var perProvider: [String: Double] = [:]
        for provider in ProviderQuota.Provider.allCases {
            if let lead = insights.leadWindow(for: provider) {
                perProvider[provider.rawValue] = lead.remainingPercent
            }
        }
        self.init(
            generatedAt: snapshot.generatedAt,
            minRemainingPercent: minRemaining,
            perProviderRemaining: perProvider,
            isDemo: snapshot.isDemo
        )
    }
}

/// Ring buffer of snapshots this device has actually observed. The Trends tab
/// renders only this — never a fabricated series.
public struct SnapshotHistoryStore: Sendable {
    public static let capacity = 500
    /// Points inside the same 10-minute bucket collapse to one.
    public static let bucketSeconds: TimeInterval = 600

    private let directory: URL

    public init(directory: URL = AppGroup.containerURL) {
        self.directory = directory
    }

    public static let shared = SnapshotHistoryStore()

    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    public func load() -> [SnapshotHistoryPoint] {
        guard let data = try? Data(contentsOf: fileURL),
              let points = try? UsageSnapshot.decoder.decode([SnapshotHistoryPoint].self, from: data)
        else { return [] }
        return points
    }

    public func save(_ points: [SnapshotHistoryPoint]) {
        guard let data = try? UsageSnapshot.encoder.encode(points) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: SnapshotFileProtection.writeOptions)
    }

    @discardableResult
    public func append(_ snapshot: UsageSnapshot) -> [SnapshotHistoryPoint] {
        guard let point = SnapshotHistoryPoint(snapshot: snapshot) else { return load() }
        let next = Self.appending(point, to: load())
        save(next)
        return next
    }

    @discardableResult
    public func seedDemo(scenario: DemoScenario, now: Date) -> [SnapshotHistoryPoint] {
        var points = load().filter { !$0.isDemo }
        points.append(contentsOf: SnapshotComposer.demoHistory(scenario: scenario, now: now))
        let next = Self.normalized(points)
        save(next)
        return next
    }

    /// Honesty rule: turning demo mode off removes every demo-flagged point so no
    /// demo residue can be presented as a real observation.
    @discardableResult
    public func clearDemoPoints() -> [SnapshotHistoryPoint] {
        let next = load().filter { !$0.isDemo }
        save(next)
        return next
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Pure helpers (unit-tested directly)

    static func appending(
        _ point: SnapshotHistoryPoint,
        to points: [SnapshotHistoryPoint]
    ) -> [SnapshotHistoryPoint] {
        var next = points
        let bucket = bucketIndex(point.generatedAt)
        if let existing = next.lastIndex(where: { bucketIndex($0.generatedAt) == bucket && $0.isDemo == point.isDemo }) {
            next[existing] = point
        } else {
            next.append(point)
        }
        return normalized(next)
    }

    static func normalized(_ points: [SnapshotHistoryPoint]) -> [SnapshotHistoryPoint] {
        let sorted = points.sorted { $0.generatedAt < $1.generatedAt }
        return sorted.count > capacity ? Array(sorted.suffix(capacity)) : sorted
    }

    static func bucketIndex(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / bucketSeconds)
    }
}
