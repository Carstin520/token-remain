import Foundation
import Testing
@testable import UsageDock

@Suite("Local AI session activity")
struct LocalAISessionActivityMonitorTests {
    @Test("Filesystem events activate a session without another recursive scan")
    func filesystemEventActivatesSession() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = LocalAISessionActivityMonitor(sessionRoots: [root])
        #expect(!monitor.hasRecentSessionActivity())

        try Data("{}\n".utf8).write(to: root.appending(path: "live-session.jsonl"))
        let deadline = ContinuousClock.now + .seconds(3)
        while !monitor.hasRecentSessionActivity(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(monitor.hasRecentSessionActivity())
    }

    @Test("Recent JSONL writes mark a session active and age out")
    func recentActivityGracePeriod() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_785_528_000)
        let session = root.appending(path: "session.jsonl")
        try Data("{}\n".utf8).write(to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30)],
            ofItemAtPath: session.path
        )

        let monitor = LocalAISessionActivityMonitor(
            sessionRoots: [root],
            now: now,
            startMonitoring: false
        )

        #expect(monitor.hasRecentSessionActivity(at: now))
        #expect(!monitor.hasRecentSessionActivity(
            at: now.addingTimeInterval(LocalAISessionActivityMonitor.activeGracePeriod + 1)
        ))
    }

    @Test("Non-session files do not keep polling active")
    func ignoresNonJSONLFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_785_528_000)
        try Data("not a session".utf8).write(to: root.appending(path: "notes.txt"))

        let monitor = LocalAISessionActivityMonitor(
            sessionRoots: [root],
            now: now,
            startMonitoring: false
        )

        #expect(!monitor.hasRecentSessionActivity(at: now))
    }

    @Test("Future filesystem timestamps are bounded to observation time")
    func futureTimestampIsBounded() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_785_528_000)
        let session = root.appending(path: "session.jsonl")
        try Data("{}\n".utf8).write(to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(86_400)],
            ofItemAtPath: session.path
        )

        let monitor = LocalAISessionActivityMonitor(
            sessionRoots: [root],
            now: now,
            startMonitoring: false
        )

        #expect(monitor.hasRecentSessionActivity(at: now))
        #expect(!monitor.hasRecentSessionActivity(
            at: now.addingTimeInterval(LocalAISessionActivityMonitor.activeGracePeriod + 1)
        ))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "LocalAISessionActivityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
