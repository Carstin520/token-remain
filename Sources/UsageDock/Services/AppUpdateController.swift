import Combine
import Sparkle

/// Bridges Sparkle's scheduled update session into a quiet, in-app reminder.
///
/// Production builds keep checking the signed appcast in the background. When
/// Sparkle finds an update, this controller suppresses the unsolicited modal
/// and exposes the version to SwiftUI instead. A user click hands control back
/// to Sparkle's standard, signed download/install/relaunch flow.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdateController()

    @Published private(set) var availableVersion: String?

    private var updaterController: SPUStandardUpdaterController?

    private override init() {
        super.init()
    }

    /// Starts Sparkle only for the signed website-distribution build.
    func start() {
        guard updaterController == nil else { return }
        // Sparkle replaces the running bundle in place. On the first launch of
        // that replacement, also recycle known historical stable install paths
        // so Finder/Spotlight cannot keep exposing an older TokenRemain copy.
        LegacyInstallationCleaner.shared.removeOlderStableCopiesAfterRelaunch()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    func presentAvailableUpdate() {
        guard let updaterController,
              updaterController.updater.canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
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

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Scheduled checks stay quiet. The sidebar reminder gives the user a
        // stable, non-interrupting way to bring Sparkle's update UI forward.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
