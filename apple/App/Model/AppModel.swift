import Foundation
import SwiftUI
import TokenRemainKit
import TokenRemainSyncKit
#if canImport(ActivityKit)
import ActivityKit
#endif

enum LiveActivityState: Equatable {
    case inactive
    case active
    case denied
}

enum MobileSyncState: Equatable {
    case off
    case pulling
    case waitingForMac
    case waitingForKey
    case synced(Date)
    case sourceChangeRequiresConfirmation(MobileSyncSourceCandidate)
    case failed(MobileSyncFailure)
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
    private(set) var dailyUsageHistory: SyncedDailyUsageHistory?
    private(set) var curatedFeed: SyncedCuratedFeed?
    var liveActivityState: LiveActivityState = .inactive
    private(set) var mobileSyncState: MobileSyncState = .off
    private(set) var syncLatencySummary: SyncLatencySummary?
    private(set) var latestSyncTiming: SyncLatencyObservation?

    /// Router state, driven by the URL scheme, widgets and `OpenTabIntent`.
    var route: TRRoute = .overview
    var highlightedWindowID: String?

    /// `-tr-force-legacy-chrome` renders the pre-iOS-26 flat path on a 26 device,
    /// so the fallback appearance can be verified without an older runtime.
    let glassEnabled: Bool

    private let settings = TRSettingsStore.shared
    private let store = SnapshotStore.shared
    private let historyStore = SnapshotHistoryStore.shared
    private let dailyUsageHistoryStore = MobileDailyUsageHistoryStore.shared
    private let curatedFeedStore = MobileCuratedFeedStore.shared
    private let syncLatencyStore = MobileSyncLatencyStore.shared
    private let watchSync = WatchSyncEngine()
    private var mobileSync: MobileSyncClient { .shared }
    private var isApplyingSyncedSnapshot = false

    var origin: SnapshotOrigin {
        didSet {
            guard origin != oldValue else { return }
            settings.origin = origin
            switch origin {
            case .none:
                historyStore.clearDemoPoints()
                dailyUsageHistoryStore.clear()
                dailyUsageHistory = nil
                curatedFeedStore.clear()
                curatedFeed = nil
                endLiveActivity()
            case .demo:
                historyStore.seedDemo(scenario: demoScenario, now: Date())
                dailyUsageHistoryStore.clear()
                dailyUsageHistory = Self.demoDailyUsageHistory(scenario: demoScenario, now: Date())
                curatedFeedStore.clear()
                curatedFeed = nil
            case .macSync:
                // Switching away from a fixture removes its synthetic history;
                // the verified Mac snapshot is appended by `install(snapshot:)`.
                historyStore.clearDemoPoints()
                dailyUsageHistory = dailyUsageHistoryStore.load()
                curatedFeed = curatedFeedStore.load()
            }
            guard !isApplyingSyncedSnapshot else { return }
            refresh()
        }
    }

    var demoScenario: DemoScenario {
        didSet {
            guard demoScenario != oldValue else { return }
            settings.demoScenario = demoScenario
            if origin == .demo {
                historyStore.seedDemo(scenario: demoScenario, now: Date())
                dailyUsageHistory = Self.demoDailyUsageHistory(scenario: demoScenario, now: Date())
            }
            refresh()
        }
    }

    var isDemoEnabled: Bool {
        get { origin == .demo }
        set { origin = newValue ? .demo : .none }
    }

    var isMacSyncEnabled: Bool { origin == .macSync }

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
        dailyUsageHistory = nil
        curatedFeed = nil
        syncLatencySummary = syncLatencyStore.summary()
        latestSyncTiming = syncLatencyStore.observations().last

        settings.origin = resolvedOrigin
        settings.demoScenario = demoScenario
        if resolvedOrigin == .none {
            historyStore.clearDemoPoints()
        } else if launchScenario != nil {
            historyStore.seedDemo(scenario: demoScenario, now: Date())
        }
        switch resolvedOrigin {
        case .macSync:
            dailyUsageHistory = dailyUsageHistoryStore.load()
            curatedFeed = curatedFeedStore.load()
        case .demo:
            dailyUsageHistory = Self.demoDailyUsageHistory(scenario: demoScenario, now: Date())
            curatedFeedStore.clear()
            curatedFeed = nil
        case .none:
            dailyUsageHistoryStore.clear()
            curatedFeedStore.clear()
            curatedFeed = nil
        }
        // `-tr-route <tab>` pins the initial tab for deterministic screenshots.
        if let index = arguments.firstIndex(of: "-tr-route"), index + 1 < arguments.count,
           let launchRoute = TRRoute(rawValue: arguments[index + 1]) {
            route = launchRoute
        }
        refresh()
        watchSync.activate()
        refreshLiveActivityState()
        mobileSyncState = resolvedOrigin == .macSync ? .waitingForMac : .off
    }

    static func launchScenario(in arguments: [String]) -> DemoScenario? {
        guard let index = arguments.firstIndex(of: "-tr-demo"), index + 1 < arguments.count else {
            return nil
        }
        return DemoScenario(rawValue: arguments[index + 1])
    }

    var insights: UsageInsights { snapshot.insights }

    func entry(at now: Date) -> TREntry { TREntry(snapshot: snapshot, now: now) }

    /// Recompose demo/empty state, or preserve the verified Mac snapshot, then
    /// fan the resulting value out to every local presentation surface.
    func refresh(now: Date = Date()) {
        if origin == .macSync {
            var preserved: UsageSnapshot
            if snapshot.origin == .macSync {
                preserved = snapshot
            } else if let stored = store.read(), stored.origin == .macSync {
                preserved = stored
            } else {
                // A persisted `.macSync` preference with no verified payload must
                // remain an honest empty state rather than falling back to demo.
                preserved = UsageSnapshot(origin: .macSync, generatedAt: now, providers: [], dailyTokens: nil)
            }
            if now.timeIntervalSince(preserved.generatedAt) > UsageSnapshot.macSyncHardExpiry {
                preserved = UsageSnapshot(
                    origin: .macSync,
                    generatedAt: preserved.generatedAt,
                    providers: [],
                    dailyTokens: nil
                )
            }
            install(snapshot: preserved, now: now)
            return
        }

        install(
            snapshot: SnapshotComposer.compose(origin: origin, scenario: demoScenario, now: now),
            now: now
        )
    }

    /// Applies a snapshot that has already passed CloudKit and AES-GCM protocol
    /// validation. This method never receives credentials, ciphertext, or raw
    /// provider errors: its only responsibility is local read-only fan-out.
    func applySyncedSnapshot(_ source: MobileUsageSnapshot, now: Date = Date()) {
        // A delayed background result must not silently re-enable a user-disabled
        // sync setting.
        guard origin == .macSync else { return }
        let adapted = MobileSnapshotAdapter.usageSnapshot(from: source)

        // Changing the persisted origin normally triggers `refresh()`. Suppress
        // that intermediate refresh so the adapted snapshot is fanned out once.
        isApplyingSyncedSnapshot = true
        origin = .macSync
        isApplyingSyncedSnapshot = false
        settings.origin = .macSync // Covers a repeated `.macSync` assignment.

        dailyUsageHistoryStore.replace(with: source.dailyUsageHistory, now: now)
        dailyUsageHistory = dailyUsageHistoryStore.load(now: now)
        curatedFeedStore.replace(with: source.curatedFeed, now: now)
        curatedFeed = curatedFeedStore.load(now: now)
        install(snapshot: adapted, now: now)
        mobileSyncState = .synced(source.generatedAt)
    }

    /// Commits a verified delivery to every presentation surface, then records
    /// the point at which the observable render model is ready. This timestamp
    /// does not claim to measure a background WidgetKit refresh.
    func applySyncedDelivery(
        _ delivery: MobileSyncDelivery,
        phoneRenderedAt: Date? = nil
    ) {
        guard origin == .macSync else { return }
        applySyncedSnapshot(delivery.snapshot, now: phoneRenderedAt ?? Date())
        let committedAt = phoneRenderedAt ?? Date()
        syncLatencySummary = syncLatencyStore.record(
            delivery,
            phoneRenderedAt: committedAt
        )
        latestSyncTiming = syncLatencyStore.observations().last
    }

    func setMacSyncEnabled(_ enabled: Bool) {
        if enabled {
            origin = .macSync
            mobileSyncState = .waitingForMac
            Task { await pullMacSync() }
        } else if origin == .macSync {
            isApplyingSyncedSnapshot = true
            origin = .none
            isApplyingSyncedSnapshot = false
            settings.origin = .none
            clearSyncedLocalData(now: Date())
            mobileSyncState = .off
            Task { await mobileSync.resetReplayState() }
        }
    }

    @discardableResult
    func pullMacSync(
        confirmedSource: MobileSyncSourceCandidate? = nil,
        now: Date = Date()
    ) async -> Bool {
        guard origin == .macSync else {
            mobileSyncState = .off
            return false
        }
        mobileSyncState = .pulling
        let outcome = await mobileSync.pull(
            confirmedSourceChange: confirmedSource?.marker,
            now: now
        )
        guard origin == .macSync else {
            mobileSyncState = .off
            return false
        }
        switch outcome {
        case .updated(let delivery):
            applySyncedDelivery(delivery)
            return true
        case .noChange(let reason):
            switch reason {
            case .noRemoteSnapshot:
                clearSyncedLocalData(now: now)
                mobileSyncState = .waitingForMac
            case .duplicate, .olderSequence:
                mobileSyncState = snapshot.origin == .macSync && !snapshot.isEmpty
                    ? .synced(snapshot.generatedAt)
                    : .waitingForMac
            }
            return false
        case .requiresSourceConfirmation(let candidate):
            mobileSyncState = .sourceChangeRequiresConfirmation(candidate)
            return false
        case .failed(.syncKeyUnavailable):
            mobileSyncState = .waitingForKey
            return false
        case .failed(let failure):
            mobileSyncState = .failed(failure)
            return false
        }
    }

    func acceptPendingMacSource() {
        guard case .sourceChangeRequiresConfirmation(let candidate) = mobileSyncState else {
            return
        }
        Task { await pullMacSync(confirmedSource: candidate) }
    }

    /// Clears every decrypted mobile copy while keeping the user's sync opt-in
    /// unchanged so a later authenticated Mac snapshot can repopulate it.
    func handleRemoteSyncCleared(now: Date = Date()) {
        guard origin == .macSync else { return }
        clearSyncedLocalData(now: now)
        mobileSyncState = .waitingForMac
    }

    private func clearSyncedLocalData(now: Date) {
        snapshot = .empty(now: now)
        store.clear()
        historyStore.clear()
        dailyUsageHistoryStore.clear()
        curatedFeedStore.clear()
        history = []
        dailyUsageHistory = nil
        curatedFeed = nil
        WidgetReload.all()
        watchSync.push(snapshot)
        endLiveActivity()
    }

    /// The only local fan-out path for newly composed or verified snapshots.
    func install(snapshot: UsageSnapshot, now: Date = Date()) {
        self.snapshot = snapshot
        store.write(snapshot)
        if snapshot.origin != .none {
            historyStore.append(snapshot)
        }
        history = historyStore.load()
        WidgetReload.all()
        watchSync.push(snapshot)
        updateLiveActivity(now: now)
    }

    private static func demoDailyUsageHistory(
        scenario: DemoScenario,
        now: Date
    ) -> SyncedDailyUsageHistory {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: now)
        let scenarioScale: Double = switch scenario {
        case .concept: 1.0
        case .freshReset: 0.65
        case .deficitPace: 1.18
        case .critical: 1.35
        }
        let days = (-13...0).compactMap { offset -> SyncedDailyUsageDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { return nil }
            let key = String(format: "%04d-%02d-%02d", year, month, day)
            let position = Double(offset + 14)
            let wave = 0.72 + Double((offset + 14) % 5) * 0.11
            return SyncedDailyUsageDay(
                day: key,
                claudeTokens: Int64(8_400_000 * scenarioScale * wave),
                claudeCost: 18.5 * scenarioScale * wave,
                codexTokens: Int64(5_700_000 * scenarioScale * (0.8 + position * 0.018)),
                codexCost: 12.4 * scenarioScale * (0.8 + position * 0.018)
            )
        }
        return SyncedDailyUsageHistory(days: days, capturedAt: now)
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
