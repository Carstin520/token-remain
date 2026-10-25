import CoreServices
import Darwin
import Foundation

/// The bundled ccusage helper re-reads the history of every agent it supports
/// on each invocation — measured at about 8 CPU-seconds, 0.8 GB of memory and
/// 33 J on a busy Mac — and a narrower `--since` barely changes that. Its
/// output depends only on those files, the report day and the configuration
/// it is given, so a scheduled run whose inputs did not change since the last
/// successful run would reproduce the snapshot already on screen.
///
/// The watch starts just before a run and stops at the first relevant change,
/// so a busy period costs one callback and an idle one costs nothing. Every
/// uncertain state runs ccusage as before: a dropped or coalesced event, an
/// input directory appearing or disappearing, a failed run, or a stream that
/// could not start. `maximumReuseAge` bounds the effect of an input this
/// catalog does not know yet, and the vendored-helper contract test fails as
/// soon as ccusage honors a data-directory variable listed nowhere below.
///
/// Codex and every other agent are tracked as separate groups, because the
/// helper can run them separately (see `CCUsageService.splitEnvironments`) and
/// Codex alone costs about nine tenths of a run.
final class CCUsageInputMonitor: @unchecked Sendable {
    static let shared = CCUsageInputMonitor()
    static let maximumReuseAge: TimeInterval = 30 * 60

    enum InputGroup: CaseIterable, Hashable, Sendable {
        /// Codex session logs and the config that selects their cost tier.
        case codex
        /// Every other agent, plus directories the app adds itself.
        case others
    }

    struct GroupInputs: Equatable, Sendable {
        /// Existing directories the helper reads recursively.
        var directories: [String] = []
        /// Individual files the helper reads, stamped by size and mtime.
        var fileStamps: [String] = []
    }

    /// Everything one group's output depends on.
    struct GroupKey: Equatable, Sendable {
        let reportDay: String
        let timeZoneIdentifier: String
        let arguments: [String]
        let sharedFileStamps: [String]
        let inputs: GroupInputs
    }

    struct Inputs: Equatable, Sendable {
        let reportDay: String
        let timeZoneIdentifier: String
        let arguments: [String]
        /// Files both groups depend on, such as the pricing configuration.
        let sharedFileStamps: [String]
        let groups: [InputGroup: GroupInputs]

        var directories: [String] {
            Array(Set(groups.values.flatMap(\.directories))).sorted()
        }

        var fileStamps: [String] {
            (sharedFileStamps + groups.values.flatMap(\.fileStamps)).sorted()
        }

        func key(for group: InputGroup) -> GroupKey {
            GroupKey(
                reportDay: reportDay,
                timeZoneIdentifier: timeZoneIdentifier,
                arguments: arguments,
                sharedFileStamps: sharedFileStamps,
                inputs: groups[group] ?? GroupInputs()
            )
        }
    }

    private struct GroupState {
        var runningKey: GroupKey?
        var reusableKey: GroupKey?
        var startedAt: Date?
        var changed = true
    }

    /// Data directories by override variable, with the home-relative
    /// defaults ccusage falls back to. Overrides are watched in addition to
    /// the defaults: watching too much only costs a run, too little costs
    /// freshness.
    static let directorySources: [(variable: String, defaults: [String])] = [
        ("OPENCODE_DATA_DIR", [".local/share/opencode"]),
        ("AMP_DATA_DIR", [".local/share/amp"]),
        ("DROID_SESSIONS_DIR", [".factory"]),
        ("CODEBUFF_DATA_DIR", [".config/manicode", ".config/manicode-staging", ".config/codebuff"]),
        ("HERMES_HOME", [".hermes"]),
        ("PI_AGENT_DIR", [".pi"]),
        ("GOOSE_PATH_ROOT", [
            ".local/share/goose",
            ".local/share/Block/goose",
            "Library/Application Support/goose"
        ]),
        ("OPENCLAW_DIR", [".openclaw", ".clawdbot", ".moltbot", ".moldbot"]),
        ("KILO_DATA_DIR", [".local/share/kilo"]),
        ("KIMI_DATA_DIR", [".kimi", ".kimi-code"]),
        ("QWEN_DATA_DIR", [".qwen"]),
        ("COPILOT_HOME", [".copilot"]),
        ("GEMINI_DATA_DIR", [".gemini"]),
        ("ANTIGRAVITY_DATA_DIR", [".gemini", ".config/antigravity"]),
        ("GROK_HOME", [".grok"]),
        ("ZCODE_HOME", [".zcode"])
    ]
    static let fileVariables = ["COPILOT_OTEL_FILE_EXPORTER_PATH"]
    /// Every path variable the vendored helper reads. Besides the tables
    /// above: Claude directories come from the app's own discovery, Codex has
    /// its own rule, the XDG bases relocate the defaults, and the offline
    /// helper keeps nothing usage-related under the cache base.
    static let recognizedEnvironmentVariables: Set<String> = Set(
        directorySources.map(\.variable) + fileVariables + [
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
            "XDG_DATA_HOME",
            "XDG_CONFIG_HOME",
            "XDG_CACHE_HOME"
        ]
    )

    private let startsEventStreams: Bool
    private let stateLock = NSLock()
    private let streamLock = NSLock()
    private var groupStates = Dictionary(
        uniqueKeysWithValues: InputGroup.allCases.map { ($0, GroupState()) }
    )
    /// Guarded by `stateLock`; read by the event callback.
    private var watchedRoots: [(path: String, group: InputGroup)] = []
    private var lastInvalidatingEvent: String?
    /// Guarded by `streamLock`.
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private let eventQueue = DispatchQueue(
        label: "com.jamesli.usagedock.ccusage-inputs",
        qos: .utility
    )

    init(startsEventStreams: Bool = true) {
        self.startsEventStreams = startsEventStreams
    }

    deinit {
        streamLock.lock()
        stopEventStreamLocked()
        streamLock.unlock()
    }

    /// Groups whose last successful result cannot stand in for a run now.
    func changedGroups(for inputs: Inputs, at now: Date) -> Set<InputGroup> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Set(InputGroup.allCases.filter { group in
            guard let state = groupStates[group],
                  !state.changed,
                  state.reusableKey == inputs.key(for: group),
                  let startedAt = state.startedAt else { return true }
            let age = now.timeIntervalSince(startedAt)
            return !(age >= 0 && age < Self.maximumReuseAge)
        })
    }

    func canReuseLastRun(for inputs: Inputs, at now: Date) -> Bool {
        changedGroups(for: inputs, at: now).isEmpty
    }

    /// Watches before the helper launches, so a write made while it is still
    /// reading also counts as a change. Groups not being run keep their state:
    /// the stream watching them is kept, or flushed before it is replaced.
    func runWillStart(
        groups: Set<InputGroup> = Set(InputGroup.allCases),
        with inputs: Inputs,
        at now: Date
    ) {
        streamLock.lock()
        defer { streamLock.unlock() }
        let roots = inputs.groups.flatMap { group, value in
            value.directories.map { (path: $0, group: group) }
        }
        stateLock.lock()
        for group in groups {
            groupStates[group] = GroupState(
                runningKey: inputs.key(for: group),
                reusableKey: nil,
                startedAt: now,
                changed: false
            )
        }
        watchedRoots = roots
        stateLock.unlock()
        guard startsEventStreams else { return }

        let paths = inputs.directories
        if stream != nil, paths == watchedPaths { return }
        let previous = stream
        stream = nil
        if !paths.isEmpty, let created = startEventStream(paths: paths) {
            stream = created
            watchedPaths = paths
        } else {
            watchedPaths = []
            if !paths.isEmpty { markInputsChanged() }
        }
        if let previous {
            // Deliver what the old stream still holds back for its latency
            // before it goes away.
            FSEventStreamFlushSync(previous)
            Self.stopEventStream(previous)
        }
    }

    func runDidFinish(groups: Set<InputGroup> = Set(InputGroup.allCases), succeeded: Bool) {
        stateLock.lock()
        for group in groups {
            guard var state = groupStates[group] else { continue }
            if succeeded {
                state.reusableKey = state.runningKey
            } else {
                state.reusableKey = nil
                state.changed = true
            }
            state.runningKey = nil
            groupStates[group] = state
        }
        stateLock.unlock()
    }

    /// The event that last invalidated a run, for diagnosing an unexpected
    /// rerun. Held in memory only.
    var lastInvalidatingEventDescription: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastInvalidatingEvent
    }

    /// Called by the event stream, and directly by tests.
    func markInputsChanged(_ groups: Set<InputGroup> = Set(InputGroup.allCases)) {
        stateLock.lock()
        for group in groups {
            groupStates[group]?.changed = true
        }
        let everythingChanged = groupStates.values.allSatisfy(\.changed)
        stateLock.unlock()
        guard everythingChanged else { return }
        // Nothing left to watch until the next run. The stream is torn down
        // off its own callback queue.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.stopEventStreamAfterChange()
        }
    }

    /// Groups an event path belongs to; a path outside every watched root
    /// (a dropped-events marker, a volume) concerns all of them.
    static func groups(
        forEventPath path: String,
        roots: [(path: String, group: InputGroup)]
    ) -> Set<InputGroup> {
        let matched = Set(roots.filter { root in
            path == root.path || path.hasPrefix(root.path + "/")
        }.map(\.group))
        return matched.isEmpty ? Set(InputGroup.allCases) : matched
    }

    // MARK: - Inputs

    static func inputs(
        for invocation: CCUsageService.Invocation,
        additionalDirectories: [URL],
        now: Date,
        timeZone: TimeZone = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Inputs {
        let environment = invocation.environment
        var directories: [URL] = []
        var files: [URL] = []
        var codexDirectories: [URL] = []
        var codexFiles: [URL] = []
        var sharedFiles: [URL] = []

        // ccusage reads `projects/` under each configured Claude directory and
        // falls back to these defaults when none is configured.
        let claudeDirectories = invocation.claudeDirectories + [
            home.appending(path: ".claude", directoryHint: .isDirectory),
            home.appending(path: ".config/claude", directoryHint: .isDirectory)
        ] + pathList(environment["CLAUDE_CONFIG_DIR"], home: home)
        for directory in claudeDirectories {
            directories.append(directory.appending(path: "projects", directoryHint: .isDirectory))
            files.append(directory.appending(path: "ccusage.json"))
        }

        // Codex homes also hold app state rewritten every few seconds; only
        // the session logs and the config that selects the cost tier matter.
        let codexHomes = [home.appending(path: ".codex", directoryHint: .isDirectory)]
            + pathList(environment["CODEX_HOME"], home: home)
        for codexHome in codexHomes {
            codexDirectories.append(codexHome.appending(path: "sessions", directoryHint: .isDirectory))
            codexDirectories.append(
                codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory)
            )
            codexFiles.append(codexHome.appending(path: "config.toml"))
        }

        let dataHome = pathList(environment["XDG_DATA_HOME"], home: home).first
        let configHome = pathList(environment["XDG_CONFIG_HOME"], home: home).first
        for source in directorySources {
            directories += pathList(environment[source.variable], home: home)
            for relative in source.defaults {
                directories.append(home.appending(path: relative, directoryHint: .isDirectory))
                if let dataHome, relative.hasPrefix(".local/share/") {
                    directories.append(dataHome.appending(
                        path: String(relative.dropFirst(".local/share/".count)),
                        directoryHint: .isDirectory
                    ))
                }
                if let configHome, relative.hasPrefix(".config/") {
                    directories.append(configHome.appending(
                        path: String(relative.dropFirst(".config/".count)),
                        directoryHint: .isDirectory
                    ))
                }
            }
        }
        for variable in fileVariables {
            files += pathList(environment[variable], home: home)
        }
        directories += additionalDirectories
        if let configuration = invocation.pricingConfigurationURL {
            sharedFiles.append(configuration)
        }
        // Without `--config` the helper also looks for a project config.
        sharedFiles.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appending(path: ".ccusage/ccusage.json")
        )

        func groupInputs(directories: [URL], files: [URL]) -> GroupInputs {
            var files = files
            var existingDirectories = Set<String>()
            for directory in directories {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        existingDirectories.insert(canonicalPath(directory.path))
                    } else {
                        files.append(directory)
                    }
                }
            }
            return GroupInputs(
                directories: existingDirectories.sorted(),
                fileStamps: Set(files.map { stamp(for: $0, fileManager: fileManager) }).sorted()
            )
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return Inputs(
            reportDay: formatter.string(from: now),
            timeZoneIdentifier: timeZone.identifier,
            arguments: invocation.arguments,
            sharedFileStamps: Set(sharedFiles.map { stamp(for: $0, fileManager: fileManager) })
                .sorted(),
            groups: [
                .codex: groupInputs(directories: codexDirectories, files: codexFiles),
                .others: groupInputs(directories: directories, files: files)
            ]
        )
    }

    private static func pathList(_ value: String?, home: URL) -> [URL] {
        guard let value else { return [] }
        return value.split(separator: ",").compactMap { component in
            let path = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            if path == "~" { return home }
            if path.hasPrefix("~/") {
                return home.appending(path: String(path.dropFirst(2)))
            }
            return URL(fileURLWithPath: path)
        }
    }

    /// FSEvents reports real paths (`/private/var/...`), so roots are compared
    /// in the same form.
    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func stamp(for url: URL, fileManager: FileManager) -> String {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return "\(url.path)|missing"
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
        return "\(url.path)|\(size)|\(modified)"
    }

    // MARK: - Event stream

    static func eventFlagsForceRun(_ flags: FSEventStreamEventFlags) -> Bool {
        let uncertain = kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
        return flags & FSEventStreamEventFlags(uncertain) != 0
    }

    /// Whether one event can change what the helper reports. Everything under
    /// a watched input directory counts except SQLite's shared-memory WAL
    /// index: readers rewrite it as well, and ccusage opening Antigravity's
    /// conversation databases touched it on every run, so each run
    /// invalidated itself. Data written by an agent changes the database or
    /// its `-wal` file.
    static func eventChangesInputs(path: String, flags: FSEventStreamEventFlags) -> Bool {
        if eventFlagsForceRun(flags) { return true }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { return false }
        return !path.hasSuffix("-shm")
    }

    private func handleEvents(count: Int, paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>) {
        var changed = Set<InputGroup>()
        stateLock.lock()
        let roots = watchedRoots
        for index in 0..<count {
            // A missing path cannot be classified; it concerns every group.
            let path = index < paths.count ? paths[index] : ""
            guard Self.eventChangesInputs(path: path, flags: flags[index]) else { continue }
            let groups = Self.groups(forEventPath: path, roots: roots)
            if !groups.isSubset(of: changed) {
                lastInvalidatingEvent = "\(path) flags=0x\(String(flags[index], radix: 16))"
            }
            changed.formUnion(groups)
        }
        stateLock.unlock()
        if !changed.isEmpty {
            markInputsChanged(changed)
        }
    }

    private func stopEventStreamAfterChange() {
        streamLock.lock()
        defer { streamLock.unlock() }
        stateLock.lock()
        let everythingChanged = groupStates.values.allSatisfy(\.changed)
        stateLock.unlock()
        // A run that started meanwhile still needs the stream.
        guard everythingChanged else { return }
        stopEventStreamLocked()
    }

    private func startEventStream(paths: [String]) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // File-level events, so a SQLite index file can be told apart from
        // the data next to it.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, contextInfo, eventCount, eventPaths, eventFlags, _ in
                guard let contextInfo else { return }
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                Unmanaged<CCUsageInputMonitor>
                    .fromOpaque(contextInfo)
                    .takeUnretainedValue()
                    .handleEvents(count: eventCount, paths: paths, flags: eventFlags)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2,
            flags
        ) else { return nil }

        FSEventStreamSetDispatchQueue(created, eventQueue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        return created
    }

    /// Must be called while `streamLock` is held.
    private func stopEventStreamLocked() {
        guard let stream else { return }
        Self.stopEventStream(stream)
        self.stream = nil
        watchedPaths = []
    }

    private static func stopEventStream(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
