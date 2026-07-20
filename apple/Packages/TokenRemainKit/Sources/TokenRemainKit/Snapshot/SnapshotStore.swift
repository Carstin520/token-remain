import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

public enum AppGroup {
    public static let identifier = "group.com.jamesli.tokenremain"

    /// The shared container, or a per-process temporary directory when the app
    /// group is unavailable (SwiftPM tests, previews).
    public static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? fallbackURL
    }

    static let fallbackURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TokenRemainFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

/// App Group JSON snapshot storage. Written only by the iOS app (on phone) and by
/// the watch app (on watch); every widget extension is read-only.
public struct SnapshotStore: Sendable {
    public static let stampKey = "tr.snapshotStamp"

    private let directory: URL
    /// `UserDefaults` is thread-safe but not `Sendable`; carry the suite name and
    /// resolve per access so the store itself stays a value type.
    private let suiteName: String?

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public init(directory: URL = AppGroup.containerURL, suiteName: String? = AppGroup.identifier) {
        self.directory = directory
        self.suiteName = suiteName
    }

    public static let shared = SnapshotStore()

    private var fileURL: URL { directory.appendingPathComponent("snapshot.json") }

    public func write(_ snapshot: UsageSnapshot) {
        guard let data = try? snapshot.encoded() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        // Cheap change token so widgets can detect a new snapshot without a file read.
        defaults.set(snapshot.generatedAt.timeIntervalSince1970, forKey: Self.stampKey)
    }

    /// Returns nil when nothing has been written, the payload is corrupt, or the
    /// schema version is unknown. Callers render `.none`.
    public func read() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UsageSnapshot.decoded(from: data)
    }

    /// Read, falling back to the honest empty snapshot.
    public func readOrEmpty(now: Date) -> UsageSnapshot {
        read() ?? .empty(now: now)
    }

    public var stamp: Double { defaults.double(forKey: Self.stampKey) }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        defaults.removeObject(forKey: Self.stampKey)
    }
}

/// Persisted user choices shared with extensions, so `RefreshSnapshotIntent` can
/// recompose without the app running.
public struct TRSettingsStore: Sendable {
    private static let originKey = "tr.origin"
    private static let scenarioKey = "tr.demoScenario"

    private let suiteName: String?

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public init(suiteName: String? = AppGroup.identifier) {
        self.suiteName = suiteName
    }

    public static let shared = TRSettingsStore()

    public var origin: SnapshotOrigin {
        get { SnapshotOrigin(rawValue: defaults.string(forKey: Self.originKey) ?? "") ?? .none }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.originKey) }
    }

    public var demoScenario: DemoScenario {
        get { DemoScenario(rawValue: defaults.string(forKey: Self.scenarioKey) ?? "") ?? .concept }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.scenarioKey) }
    }
}

public enum WidgetReload {
    public static func all() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
