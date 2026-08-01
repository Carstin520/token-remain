import CoreServices
import Foundation

/// Watches append-only Codex/Claude session logs instead of treating a running
/// desktop app or long-lived app-server process as proof of active model work.
/// FSEvents makes the steady-state probe a lock + timestamp read; the recursive
/// filesystem walk happens only once at launch to seed an already-running
/// session.
final class LocalAISessionActivityMonitor: @unchecked Sendable {
    static let activeGracePeriod: TimeInterval = 3 * 60
    static let shared = LocalAISessionActivityMonitor()

    private let sessionRoots: [URL]
    private let fileManager: FileManager
    private let monitoringEnabled: Bool
    private let lock = NSLock()
    private let streamLock = NSLock()
    private var latestActivityAt: Date? = nil
    private var stream: FSEventStreamRef?
    private var monitoredPaths: Set<String> = []
    private let eventQueue = DispatchQueue(
        label: "com.jamesli.usagedock.session-activity",
        qos: .utility
    )

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sessionRoots: [URL]? = nil,
        fileManager: FileManager = .default,
        now: Date = .now,
        startMonitoring: Bool = true
    ) {
        let roots = sessionRoots ?? Self.defaultSessionRoots(homeDirectory: homeDirectory)
        self.sessionRoots = roots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.fileManager = fileManager
        monitoringEnabled = startMonitoring
        if startMonitoring {
            refreshEventStreamIfNeeded(at: now)
        } else {
            latestActivityAt = Self.latestSessionModificationDate(
                under: self.sessionRoots,
                fileManager: fileManager,
                noLaterThan: now
            )
        }
    }

    deinit {
        streamLock.lock()
        stopEventStreamLocked()
        streamLock.unlock()
    }

    func hasRecentSessionActivity(
        at now: Date = .now,
        gracePeriod: TimeInterval = activeGracePeriod
    ) -> Bool {
        if monitoringEnabled {
            // This rides the existing minute-level activity probe, so a session
            // root created after app launch gains monitoring without another
            // timer or permanent watch on the user's whole home directory.
            refreshEventStreamIfNeeded(at: now)
        }
        lock.lock()
        // The event callback can race this probe after `now` was captured. It
        // may therefore publish a timestamp a few milliseconds in the future;
        // a system clock rollback can create the same shape. Clamp and persist
        // the observation so activity remains true now but still ages out.
        if let latestActivityAt, latestActivityAt > now {
            self.latestActivityAt = now
        }
        let latest = latestActivityAt
        lock.unlock()
        guard let latest else { return false }
        let age = now.timeIntervalSince(latest)
        return age >= 0 && age <= gracePeriod
    }

    static func defaultSessionRoots(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory),
            homeDirectory.appending(
                path: "Library/Application Support/Claude/local-agent-mode-sessions",
                directoryHint: .isDirectory
            )
        ]
    }

    static func latestSessionModificationDate(
        under roots: [URL],
        fileManager: FileManager = .default,
        noLaterThan now: Date = .now
    ) -> Date? {
        var latest: Date?
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "jsonl",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate
                else { continue }
                let bounded = min(modifiedAt, now)
                if latest.map({ bounded > $0 }) ?? true {
                    latest = bounded
                }
            }
        }
        return latest
    }

    private func refreshEventStreamIfNeeded(at now: Date) {
        let currentPaths = Set(sessionRoots
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map(\.path))

        streamLock.lock()
        guard currentPaths != monitoredPaths else {
            streamLock.unlock()
            return
        }
        stopEventStreamLocked()
        let started = startEventStreamLocked(paths: currentPaths.sorted())
        monitoredPaths = started ? currentPaths : []
        streamLock.unlock()

        // Start the stream before seeding when possible. A file written during
        // the seed walk is then covered by either path. If FSEvents is
        // temporarily unavailable, seed correctness still wins and the next
        // minute probe retries stream creation.
        // Re-seed every currently available root whenever the watched topology
        // changes. Rebuilding the stream has a tiny stop/start gap, and a write
        // to an already-watched root during that gap must not be lost either.
        guard !currentPaths.isEmpty else { return }
        let currentRoots = sessionRoots.filter { currentPaths.contains($0.path) }
        if let seededAt = Self.latestSessionModificationDate(
            under: currentRoots,
            fileManager: fileManager,
            noLaterThan: now
        ) {
            recordActivity(at: seededAt)
        }
    }

    /// Must be called while `streamLock` is held.
    private func startEventStreamLocked(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, contextInfo, _, eventPaths, _, _ in
                guard let contextInfo else { return }
                let monitor = Unmanaged<LocalAISessionActivityMonitor>
                    .fromOpaque(contextInfo)
                    .takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                monitor.recordEvents(paths: paths, at: .now)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1,
            flags
        ) else { return false }

        stream = created
        FSEventStreamSetDispatchQueue(created, eventQueue)
        if !FSEventStreamStart(created) {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return false
        }
        return true
    }

    /// Must be called while `streamLock` is held.
    private func stopEventStreamLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func recordEvents(paths: [String], at date: Date) {
        guard paths.contains(where: { path in
            let canonicalPath = URL(filePath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            return canonicalPath.lowercased().hasSuffix(".jsonl")
                && sessionRoots.contains { root in
                    canonicalPath == root.path || canonicalPath.hasPrefix(root.path + "/")
                }
        }) else { return }
        recordActivity(at: date)
    }

    private func recordActivity(at date: Date) {
        lock.lock()
        if latestActivityAt.map({ date > $0 }) ?? true {
            latestActivityAt = date
        }
        lock.unlock()
    }
}
