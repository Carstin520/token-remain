import AppIntents
import Foundation

/// Deep-link / tab routing shared by widgets, intents and the URL scheme.
public enum TRRoute: String, Sendable, CaseIterable {
    case overview, limits, trends, settings

    public static let scheme = "tokenremain"

    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    public static func windowURL(_ windowID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = TRRoute.limits.rawValue
        components.path = "/" + windowID
        return components.url ?? TRRoute.limits.url
    }

    /// Parses `tokenremain://limits/<windowID>` into a route + optional anchor.
    public static func parse(_ url: URL) -> (route: TRRoute, windowID: String?)? {
        guard url.scheme == scheme, let host = url.host, let route = TRRoute(rawValue: host) else {
            return nil
        }
        let anchor = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding
        return (route, anchor?.isEmpty == false ? anchor : nil)
    }

    /// Written to the App Group so `OpenTabIntent` can hand a destination to the app.
    static let pendingRouteKey = "tr.pendingRoute"

    public static func setPending(_ route: TRRoute, defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(route.rawValue, forKey: pendingRouteKey)
    }

    public static func takePending(defaults: UserDefaults = AppGroup.defaults) -> TRRoute? {
        guard let raw = defaults.string(forKey: pendingRouteKey) else { return nil }
        defaults.removeObject(forKey: pendingRouteKey)
        return TRRoute(rawValue: raw)
    }
}

public enum TRTabEntity: String, AppEnum {
    case overview, limits, trends, settings

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Token Remain Tab" }

    // The AppIntents metadata processor extracts these at build time, so they must
    // be static literals rather than runtime lookups.
    public static var caseDisplayRepresentations: [TRTabEntity: DisplayRepresentation] {
        [
            .overview: "Overview",
            .limits: "Limits",
            .trends: "Trends",
            .settings: "Settings"
        ]
    }

    public var route: TRRoute { TRRoute(rawValue: rawValue) ?? .overview }
}

/// Recomposes the snapshot at the current instant, persists it to the App Group,
/// reloads widgets and updates a running Live Activity. Runs entirely in-process —
/// there is nothing to fetch, because there is no source to fetch from.
public struct RefreshSnapshotIntent: AppIntent {
    public static var title: LocalizedStringResource { "Refresh quota" }
    public static var description: IntentDescription {
        IntentDescription("Recompose the Token Remain snapshot and refresh every surface.")
    }
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let settings = TRSettingsStore.shared
        let snapshot = SnapshotComposer.compose(
            origin: settings.origin,
            scenario: settings.demoScenario,
            now: now
        )
        SnapshotStore.shared.write(snapshot)
        if snapshot.origin == .demo {
            SnapshotHistoryStore.shared.append(snapshot)
        }
        WidgetReload.all()

        let entry = TREntry(snapshot: snapshot, now: now)
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
            await LiveActivityCoordinator.update(entry: entry, now: now)
        }
        #endif

        guard entry.hasNumbers else {
            return .result(dialog: IntentDialog(stringLiteral: TRL10n.t("intent.refresh.none")))
        }
        return .result(
            dialog: IntentDialog(stringLiteral: TRL10n.f("intent.refresh.done", entry.heroText))
        )
    }
}

public struct OpenTabIntent: AppIntent {
    public static var title: LocalizedStringResource { "Open Token Remain" }
    public static var openAppWhenRun: Bool { true }

    @Parameter(title: "Tab")
    public var tab: TRTabEntity

    public init() {
        self.tab = .overview
    }

    public init(tab: TRTabEntity) {
        self.tab = tab
    }

    public func perform() async throws -> some IntentResult {
        TRRoute.setPending(tab.route)
        return .result()
    }
}

#if os(iOS)
public struct StartLiveActivityIntent: AppIntent {
    public static var title: LocalizedStringResource { "Start Live Activity" }
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let snapshot = SnapshotStore.shared.readOrEmpty(now: now)
        let entry = TREntry(snapshot: snapshot, now: now)
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *), LiveActivityCoordinator.start(entry: entry, now: now) {
            return .result(dialog: IntentDialog(stringLiteral: TRL10n.t("intent.startla.done")))
        }
        #endif
        return .result(dialog: IntentDialog(stringLiteral: TRL10n.t("settings.liveactivity.needsdemo")))
    }
}

public struct StopLiveActivityIntent: AppIntent {
    public static var title: LocalizedStringResource { "Stop Live Activity" }
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            await LiveActivityCoordinator.end(now: Date())
        }
        #endif
        return .result(dialog: IntentDialog(stringLiteral: TRL10n.t("intent.stopla.done")))
    }
}
#endif
