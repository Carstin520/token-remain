import Foundation
import Testing
@testable import UsageDock

@Suite("Remote app update checks")
struct AppUpdateCheckPolicyTests {
    @Test("Polling becomes quieter after finding an update and backs off after failures")
    func adaptiveCadence() {
        #expect(AppUpdateCheckPolicy.nextDelay(
            hasAvailableUpdate: false,
            consecutiveFailures: 0
        ) == 6 * 60 * 60)
        #expect(AppUpdateCheckPolicy.nextDelay(
            hasAvailableUpdate: true,
            consecutiveFailures: 0
        ) == 12 * 60 * 60)
        #expect(AppUpdateCheckPolicy.nextDelay(
            hasAvailableUpdate: false,
            consecutiveFailures: 1
        ) == 60 * 60)
        #expect(AppUpdateCheckPolicy.nextDelay(
            hasAvailableUpdate: true,
            consecutiveFailures: 2
        ) == 3 * 60 * 60)
        #expect(AppUpdateCheckPolicy.nextDelay(
            hasAvailableUpdate: true,
            consecutiveFailures: 8
        ) == 6 * 60 * 60)
    }

    @Test("Relaunch respects the last probe without hiding an overdue check")
    func initialDelayUsesPersistedCheckTime() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(AppUpdateCheckPolicy.initialDelay(
            now: now,
            lastCheckDate: nil,
            hasAvailableUpdate: false
        ) == 0)
        #expect(AppUpdateCheckPolicy.initialDelay(
            now: now,
            lastCheckDate: now.addingTimeInterval(-5 * 60 * 60),
            hasAvailableUpdate: false
        ) == 60 * 60)
        #expect(AppUpdateCheckPolicy.initialDelay(
            now: now,
            lastCheckDate: now.addingTimeInterval(-13 * 60 * 60),
            hasAvailableUpdate: true
        ) == 0)
        #expect(AppUpdateCheckPolicy.initialDelay(
            now: now,
            lastCheckDate: now.addingTimeInterval(60),
            hasAvailableUpdate: false
        ) == 0)
    }

    @Test("Only a strictly newer persisted build may restore an update reminder")
    func persistedReminderMustStillBeNewer() {
        #expect(AppUpdateCheckPolicy.isNewerBuild("15", than: "14"))
        #expect(AppUpdateCheckPolicy.isNewerBuild("14.1", than: "14"))
        #expect(!AppUpdateCheckPolicy.isNewerBuild("14", than: "14.0"))
        #expect(!AppUpdateCheckPolicy.isNewerBuild("13", than: "14"))
        #expect(!AppUpdateCheckPolicy.isNewerBuild("latest", than: "14"))
    }
}
