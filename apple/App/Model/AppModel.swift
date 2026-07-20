import Foundation
import SwiftUI
import TokenRemainKit
#if canImport(ActivityKit)
import ActivityKit
#endif

enum LiveActivityState: Equatable {
    case inactive
    case active
    case denied
}

/// Owns app state and orchestrates the one-way flow:
/// `origin/scenario` → compose → store → history → widgets → watch → Live Activity.
/// All derivation lives in the kit; this type only sequences it. There are no
/// timers here — time-varying text uses `TimelineView` / `Text(timerInterval:)`.
@Observable
@MainActor
final class AppModel {
    private(set) var snapshot: UsageSnapshot
    private(set) var history: [SnapshotHistoryPoint]
    var liveActivityState: LiveActivityState = .inactive

    /// Router state, driven by the URL scheme, widgets and `OpenTabIntent`.
    var route: TRRoute = .overview
    var highlightedWindowID: String?

    /// `-tr-force-legacy-chrome` renders the pre-iOS-26 flat path on a 26 device,
    /// so the fallback appearance can be verified without an older runtime.
    let glassEnabled: Bool

    private let settings = TRSettingsStore.shared
    private let store = SnapshotStore.shared
    private let historyStore = SnapshotHistoryStore.shared
    private let watchSync = WatchSyncEngine()

    var origin: SnapshotOrigin {
        didSet {
            guard origin != oldValue else { return }
            settings.origin = origin
            if origin == .none {
                historyStore.clearDemoPoints()
                endLiveActivity()
            } else {
                historyStore.seedDemo(scenario: demoScenario, now: Date())
            }
            refresh()
        }
    }

    var demoScenario: DemoScenario {
        didSet {
            guard demoScenario != oldValue else { return }
            settings.demoScenario = demoScenario
            if origin == .demo {
                historyStore.seedDemo(scenario: demoScenario, now: Date())
            }
            refresh()
        }
    }

    var isDemoEnabled: Bool {
        get { origin == .demo }
        set { origin = newValue ? .demo : .none }
    }

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        glassEnabled = !arguments.contains("-tr-force-legacy-chrome")

        // UI tests pin the origin and scenario so every assertion is deterministic
        // and independent of whatever the previous run persisted.
        let launchScenario = Self.launchScenario(in: arguments)
        let forcedNone = arguments.contains("-tr-origin-none")
        let resolvedOrigin: SnapshotOrigin
        if forcedNone {
            resolvedOrigin = .none
        } else if launchScenario != nil {
            resolvedOrigin = .demo
        } else {
            resolvedOrigin = TRSettingsStore.shared.origin
        }
        origin = resolvedOrigin
        demoScenario = launchScenario ?? TRSettingsStore.shared.demoScenario
        snapshot = .empty(now: Date())
        history = []

        settings.origin = resolvedOrigin
        settings.demoScenario = demoScenario
        if resolvedOrigin == .none {
            historyStore.clearDemoPoints()
        } else if launchScenario != nil {
            historyStore.seedDemo(scenario: demoScenario, now: Date())
        }
        // `-tr-route <tab>` pins the initial tab for deterministic screenshots.
        if let index = arguments.firstIndex(of: "-tr-route"), index + 1 < arguments.count,
           let launchRoute = TRRoute(rawValue: arguments[index + 1]) {
            route = launchRoute
        }
        refresh()
        watchSync.activate()
        refreshLiveActivityState()
    }

    static func launchScenario(in arguments: [String]) -> DemoScenario? {
        guard let index = arguments.firstIndex(of: "-tr-demo"), index + 1 < arguments.count else {
            return nil
        }
        return DemoScenario(rawValue: arguments[index + 1])
    }

    var insights: UsageInsights { snapshot.insights }

    func entry(at now: Date) -> TREntry { TREntry(snapshot: snapshot, now: now) }

    /// Recompose from the current origin/scenario and fan the result out to every surface.
    func refresh(now: Date = Date()) {
        let composed = SnapshotComposer.compose(origin: origin, scenario: demoScenario, now: now)
        snapshot = composed
        store.write(composed)
        if composed.origin != .none {
            historyStore.append(composed)
        }
        history = historyStore.load()
        WidgetReload.all()
        watchSync.push(composed)
        updateLiveActivity(now: now)
    }

    /// The Overview CTA and widget deep links land here.
    func open(route: TRRoute, windowID: String? = nil) {
        self.route = route
        highlightedWindowID = windowID
    }

    func handle(url: URL) {
        guard let parsed = TRRoute.parse(url) else { return }
        open(route: parsed.route, windowID: parsed.windowID)
    }

    /// Called on foreground: picks up a destination left by `OpenTabIntent`.
    func consumePendingRoute() {
        if let pending = TRRoute.takePending() {
            open(route: pending)
        }
    }

    func openConstrainingWindow() {
        guard let window = insights.constrainingWindow else { return }
        open(route: .limits, windowID: window.id)
    }

    // MARK: - Live Activity

    func refreshLiveActivityState() {
        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *) else {
            liveActivityState = .denied
            return
        }
        guard LiveActivityCoordinator.areActivitiesEnabled else {
            liveActivityState = .denied
            return
        }
        liveActivityState = LiveActivityCoordinator.isRunning ? .active : .inactive
        #else
        liveActivityState = .denied
        #endif
    }

    func startLiveActivity(now: Date = Date()) {
        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *) else { return }
        _ = LiveActivityCoordinator.start(entry: entry(at: now), now: now)
        refreshLiveActivityState()
        #endif
    }

    func endLiveActivity() {
        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *) else { return }
        Task {
            await LiveActivityCoordinator.end(now: Date())
            refreshLiveActivityState()
        }
        #endif
    }

    private func updateLiveActivity(now: Date) {
        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *) else { return }
        let entry = entry(at: now)
        Task {
            await LiveActivityCoordinator.update(entry: entry, now: now)
            refreshLiveActivityState()
        }
        #endif
    }

    // MARK: - Watch status (surfaced in Settings)

    var watchStatus: WatchSyncEngine.Status { watchSync.status }
}
