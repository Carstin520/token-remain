import AppKit
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        let previousValue = isEnabled
        isEnabled = enabled
        errorMessage = nil

        Task {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
                isEnabled = SMAppService.mainApp.status == .enabled
                if enabled && !isEnabled {
                    errorMessage = L10n.text("launch.allow_in_system_settings")
                }
            } catch {
                isEnabled = previousValue
                errorMessage = L10n.format("launch.update_failed", error.localizedDescription)
            }
        }
    }

    func restart() {
        errorMessage = nil
        Task {
            do {
                _ = try await ProcessRunner.run(
                    "/usr/bin/open",
                    arguments: ["-n", AppResourceBundle.bundle.bundleURL.path]
                )
                NSApplication.shared.terminate(nil)
            } catch {
                errorMessage = L10n.format("launch.restart_failed", error.localizedDescription)
            }
        }
    }
}
