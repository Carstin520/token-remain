import Combine
import Foundation
import Sparkle

/// Pure scheduling rules for remote update discovery.
///
/// Background probes only fetch and validate the signed appcast. They never
/// download an installer, so a discovered release cannot become a stale
/// resumable update that prevents Sparkle from seeing a newer release later.
struct AppUpdateCheckPolicy {
    static let noUpdateInterval: TimeInterval = 6 * 60 * 60
    static let updateAvailableInterval: TimeInterval = 12 * 60 * 60
    static let busyRetryInterval: TimeInterval = 15 * 60

    static func nextDelay(
        hasAvailableUpdate: Bool,
        consecutiveFailures: Int
    ) -> TimeInterval {
        switch consecutiveFailures {
        case ...0:
            return hasAvailableUpdate ? updateAvailableInterval : noUpdateInterval
        case 1:
            return 60 * 60
        case 2:
            return 3 * 60 * 60
        default:
            return 6 * 60 * 60
        }
    }

    static func initialDelay(
        now: Date,
        lastCheckDate: Date?,
        hasAvailableUpdate: Bool
    ) -> TimeInterval {
        guard let lastCheckDate,
              lastCheckDate <= now else { return 0 }
        let interval = nextDelay(
            hasAvailableUpdate: hasAvailableUpdate,
            consecutiveFailures: 0
        )
        return max(0, interval - now.timeIntervalSince(lastCheckDate))
    }

    static func isNewerBuild(_ candidate: String, than current: String) -> Bool {
        guard let candidateComponents = buildComponents(candidate),
              let currentComponents = buildComponents(current) else { return false }
        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidatePart = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentPart = index < currentComponents.count ? currentComponents[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    private static func buildComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let components = parts.compactMap { part -> Int? in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        return components.count == parts.count ? components : nil
    }
}

/// Bridges signed Sparkle checks into a quiet, in-app reminder.
///
/// Scheduled work uses information-only probes that finish immediately and
/// leave no downloaded update behind. When the user clicks the reminder, a
/// fresh user-initiated Sparkle check selects the newest compatible item from
/// the current appcast before any download or installation begins.
@MainActor
final class AppUpdateController: NSObject, ObservableObject,
    SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdateController()

    @Published private(set) var availableVersion: String?

    private enum DefaultsKey {
        static let availableDisplayVersion = "TokenRemainAvailableUpdateDisplayVersion"
        static let availableBuildVersion = "TokenRemainAvailableUpdateBuildVersion"
    }

    private let defaults: UserDefaults
    private var updaterController: SPUStandardUpdaterController?
    private var scheduledProbeTask: Task<Void, Never>?
    private var nextScheduledProbeAt: Date?
    private var scheduledProbeInFlight = false
    private var scheduledProbeReceivedAnswer = false
    private var userCheckInProgress = false
    private var queuedUserCheck = false
    private var consecutiveProbeFailures = 0

    private override init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults

        let storedDisplayVersion = defaults.string(forKey: DefaultsKey.availableDisplayVersion)
        let storedBuildVersion = defaults.string(forKey: DefaultsKey.availableBuildVersion)
        let currentBuildVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        if let storedDisplayVersion,
           let storedBuildVersion,
           let currentBuildVersion,
           AppUpdateCheckPolicy.isNewerBuild(storedBuildVersion, than: currentBuildVersion) {
            availableVersion = storedDisplayVersion
        } else {
            availableVersion = nil
            defaults.removeObject(forKey: DefaultsKey.availableDisplayVersion)
            defaults.removeObject(forKey: DefaultsKey.availableBuildVersion)
        }

        super.init()
    }

    /// Starts Sparkle only for the signed website-distribution build.
    func start() {
        guard updaterController == nil else { return }
        // Sparkle replaces the running bundle in place. On the first launch of
        // that replacement, also recycle known historical stable install paths
        // so Finder/Spotlight cannot keep exposing an older TokenRemain copy.
        LegacyInstallationCleaner.shared.removeOlderStableCopiesAfterRelaunch()

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController = controller

        // Migrate any previous Sparkle preferences away from automatic checks
        // and downloads. A downloaded update is resumable and pins that exact
        // version; information probes do not, which lets every later check see
        // the newest item in the signed appcast.
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.automaticallyChecksForUpdates = false
        controller.startUpdater()

        let initialDelay = AppUpdateCheckPolicy.initialDelay(
            now: Date(),
            lastCheckDate: controller.updater.lastUpdateCheckDate,
            hasAvailableUpdate: availableVersion != nil
        )
        scheduleNextProbe(after: initialDelay)
    }

    /// Called when the application becomes active so sleep/wake cannot leave an
    /// overdue probe waiting on an old timer deadline.
    func checkIfDue(now: Date = Date()) {
        guard let nextScheduledProbeAt,
              now >= nextScheduledProbeAt else { return }
        scheduledProbeTask?.cancel()
        performScheduledProbe()
    }

    func presentAvailableUpdate() {
        guard let updaterController else { return }

        // If a fresh user check is already presenting Sparkle UI, bring that UI
        // forward. Otherwise queue a new check; unlike a cached downloaded
        // update, this fetches the current appcast before offering installation.
        if userCheckInProgress {
            updaterController.checkForUpdates(nil)
            return
        }

        queuedUserCheck = true
        scheduledProbeTask?.cancel()
        nextScheduledProbeAt = nil
        startQueuedUserCheckIfPossible()
    }

#if DEBUG
    /// Visual-QA hook for the packaged development app. It never starts
    /// Sparkle, so clicking the preview reminder cannot modify an installation.
    func configurePreview(arguments: [String]) {
        guard updaterController == nil,
              let flagIndex = arguments.firstIndex(of: "--preview-update-version"),
              arguments.indices.contains(flagIndex + 1) else { return }
        availableVersion = arguments[flagIndex + 1]
    }
#endif

    private func scheduleNextProbe(after delay: TimeInterval) {
        scheduledProbeTask?.cancel()
        let boundedDelay = max(0, delay)
        nextScheduledProbeAt = Date().addingTimeInterval(boundedDelay)
        scheduledProbeTask = Task { @MainActor [weak self] in
            if boundedDelay > 0 {
                try? await Task.sleep(for: .seconds(boundedDelay))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            self?.performScheduledProbe()
        }
    }

    private func performScheduledProbe() {
        guard let updater = updaterController?.updater else { return }
        nextScheduledProbeAt = nil

        if queuedUserCheck {
            startQueuedUserCheckIfPossible()
            return
        }
        guard !userCheckInProgress else { return }
        guard !updater.sessionInProgress,
              updater.canCheckForUpdates else {
            scheduleNextProbe(after: AppUpdateCheckPolicy.busyRetryInterval)
            return
        }

        scheduledProbeInFlight = true
        scheduledProbeReceivedAnswer = false
        updater.checkForUpdateInformation()
    }

    private func startQueuedUserCheckIfPossible() {
        guard queuedUserCheck,
              let updaterController else { return }
        let updater = updaterController.updater
        guard !updater.sessionInProgress,
              updater.canCheckForUpdates else { return }

        queuedUserCheck = false
        userCheckInProgress = true
        updaterController.checkForUpdates(nil)
    }

    private func recordAvailableUpdate(_ update: SUAppcastItem) {
        availableVersion = update.displayVersionString
        defaults.set(update.displayVersionString, forKey: DefaultsKey.availableDisplayVersion)
        defaults.set(update.versionString, forKey: DefaultsKey.availableBuildVersion)
    }

    private func clearAvailableUpdate() {
        availableVersion = nil
        defaults.removeObject(forKey: DefaultsKey.availableDisplayVersion)
        defaults.removeObject(forKey: DefaultsKey.availableBuildVersion)
    }

    private func scheduleAfterFinishedCycle() {
        let delay = AppUpdateCheckPolicy.nextDelay(
            hasAvailableUpdate: availableVersion != nil,
            consecutiveFailures: consecutiveProbeFailures
        )
        scheduleNextProbe(after: delay)
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if scheduledProbeInFlight {
            scheduledProbeReceivedAnswer = true
        }
        recordAvailableUpdate(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if scheduledProbeInFlight {
            scheduledProbeReceivedAnswer = true
        }
        clearAvailableUpdate()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        switch updateCheck {
        case .updateInformation:
            scheduledProbeInFlight = false
            if scheduledProbeReceivedAnswer {
                consecutiveProbeFailures = 0
            } else {
                consecutiveProbeFailures += 1
            }
            scheduledProbeReceivedAnswer = false
        case .updates:
            userCheckInProgress = false
        case .updatesInBackground:
            break
        @unknown default:
            break
        }

        if queuedUserCheck {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.startQueuedUserCheckIfPossible()
            }
        } else {
            scheduleAfterFinishedCycle()
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // This is a defensive fallback. TokenRemain's scheduled work uses
        // information probes, so only a user-initiated check should reach the
        // standard Sparkle UI.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        recordAvailableUpdate(update)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearAvailableUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Keep a probe-discovered reminder across transient user-check errors.
        // It is cleared when the user sees the update UI or a later probe
        // confirms there is no newer compatible version.
    }
}
