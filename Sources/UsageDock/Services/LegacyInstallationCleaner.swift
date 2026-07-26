import AppKit
import Foundation
import OSLog

struct InstalledAppIdentity: Equatable {
    let bundleIdentifier: String
    let version: String
    let build: String
}

enum LegacyInstallationCleanupPolicy {
    static let stableBundleIdentifier = "com.jamesli.usagedock"

    static func removableStableCopies(
        currentApplicationURL: URL,
        candidateURLs: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let current = identity(at: currentApplicationURL),
              current.bundleIdentifier == stableBundleIdentifier
        else { return [] }

        let currentPath = currentApplicationURL.standardizedFileURL.path
        return candidateURLs.filter { candidateURL in
            let candidate = candidateURL.standardizedFileURL
            guard candidate.path != currentPath,
                  fileManager.fileExists(atPath: candidate.path),
                  let identity = identity(at: candidate),
                  identity.bundleIdentifier == stableBundleIdentifier
            else { return false }

            return compare(identity, to: current) != .orderedDescending
        }
    }

    static func identity(at applicationURL: URL) -> InstalledAppIdentity? {
        let infoURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let info = propertyList as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String
        else { return nil }

        return InstalledAppIdentity(
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build
        )
    }

    private static func compare(
        _ lhs: InstalledAppIdentity,
        to rhs: InstalledAppIdentity
    ) -> ComparisonResult {
        let versionResult = lhs.version.compare(rhs.version, options: .numeric)
        guard versionResult == .orderedSame else { return versionResult }
        return lhs.build.compare(rhs.build, options: .numeric)
    }
}

/// After Sparkle relaunches the newly installed build, remove only known legacy
/// stable-install aliases that are no newer than the running app. Development
/// builds, release archives, source trees and arbitrary filesystem locations are
/// deliberately outside this allowlist.
@MainActor
final class LegacyInstallationCleaner {
    static let shared = LegacyInstallationCleaner()

    private static let logger = Logger(
        subsystem: "com.jamesli.usagedock",
        category: "LegacyInstallationCleaner"
    )

    private init() {}

    func removeOlderStableCopiesAfterRelaunch(
        currentApplicationURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let candidates = [
            homeDirectory.appendingPathComponent("Applications/TokenRemain.app"),
            homeDirectory.appendingPathComponent("Applications/UsageDock.app"),
            homeDirectory.appendingPathComponent("Applications/Token Remain.app"),
            URL(fileURLWithPath: "/Applications/UsageDock.app"),
            URL(fileURLWithPath: "/Applications/Token Remain.app")
        ]
        let removable = LegacyInstallationCleanupPolicy.removableStableCopies(
            currentApplicationURL: currentApplicationURL,
            candidateURLs: candidates
        )
        guard !removable.isEmpty else { return }

        let logger = Self.logger
        NSWorkspace.shared.recycle(removable) { movedURLs, error in
            if let error {
                logger.error(
                    "Could not recycle legacy installations: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            let movedCount = movedURLs.count
            logger.info("Recycled \(movedCount, privacy: .public) legacy installation(s)")
        }
    }
}
