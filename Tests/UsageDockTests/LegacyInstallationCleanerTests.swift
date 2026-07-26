import Foundation
import Testing
@testable import UsageDock

@Suite("Legacy installation cleanup")
struct LegacyInstallationCleanerTests {
    @Test("Only known stable copies no newer than the running app are removable")
    func cleanupPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenRemainCleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let current = try makeApp(
            at: root.appendingPathComponent("Current.app"),
            bundleIdentifier: "com.jamesli.usagedock",
            version: "1.1.7",
            build: "9"
        )
        let older = try makeApp(
            at: root.appendingPathComponent("Older.app"),
            bundleIdentifier: "com.jamesli.usagedock",
            version: "1.1.5",
            build: "7"
        )
        let duplicate = try makeApp(
            at: root.appendingPathComponent("Duplicate.app"),
            bundleIdentifier: "com.jamesli.usagedock",
            version: "1.1.7",
            build: "9"
        )
        let newer = try makeApp(
            at: root.appendingPathComponent("Newer.app"),
            bundleIdentifier: "com.jamesli.usagedock",
            version: "1.1.10",
            build: "12"
        )
        let development = try makeApp(
            at: root.appendingPathComponent("Development.app"),
            bundleIdentifier: "com.jamesli.usagedock.dev",
            version: "1.1.6",
            build: "8"
        )

        let removable = LegacyInstallationCleanupPolicy.removableStableCopies(
            currentApplicationURL: current,
            candidateURLs: [current, older, duplicate, newer, development]
        )

        #expect(Set(removable) == Set([older, duplicate]))
    }

    @Test("A development build can never clean stable installations")
    func developmentBuildIsIneligible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenRemainCleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let current = try makeApp(
            at: root.appendingPathComponent("CurrentDev.app"),
            bundleIdentifier: "com.jamesli.usagedock.dev",
            version: "1.1.7",
            build: "9"
        )
        let stable = try makeApp(
            at: root.appendingPathComponent("Stable.app"),
            bundleIdentifier: "com.jamesli.usagedock",
            version: "1.1.5",
            build: "7"
        )

        #expect(LegacyInstallationCleanupPolicy.removableStableCopies(
            currentApplicationURL: current,
            candidateURLs: [stable]
        ).isEmpty)
    }

    private func makeApp(
        at applicationURL: URL,
        bundleIdentifier: String,
        version: String,
        build: String
    ) throws -> URL {
        let contents = applicationURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return applicationURL
    }
}
