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
    private let lock = NSLock()
    private var latestActivityAt: Date?
    private var stream: FSEventStreamRef?
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
        latestActivityAt = Self.latestSessionModificationDate(
            under: self.sessionRoots,
            fileManager: fileManager,
            noLaterThan: now
        )
        if startMonitoring {
            startEventStream(fileManager: fileManager)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func hasRecentSessionActivity(
        at now: Date = .now,
        gracePeriod: TimeInterval = activeGracePeriod
    ) -> Bool {
        lock.lock()
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

    private func startEventStream(fileManager: FileManager) {
        let paths = sessionRoots
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map(\.path)
        guard !paths.isEmpty else { return }

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
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, eventQueue)
        if !FSEventStreamStart(created) {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
        }
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
        lock.lock()
        if latestActivityAt.map({ date > $0 }) ?? true {
            latestActivityAt = date
        }
        lock.unlock()
    }
}
