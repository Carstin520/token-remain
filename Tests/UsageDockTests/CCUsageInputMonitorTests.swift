import CoreServices
import Foundation
import Testing
@testable import UsageDock

@Suite("ccusage input monitor")
struct CCUsageInputMonitorTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func invocation(
        claudeDirectories: [URL] = [],
        environment: [String: String] = [:],
        configuration: URL? = nil,
        arguments: [String] = ["daily", "--since", "20270101"]
    ) -> CCUsageService.Invocation {
        CCUsageService.Invocation(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: arguments,
            environment: environment,
            claudeDirectories: claudeDirectories,
            pricingConfigurationURL: configuration
        )
    }

    private static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "ccusage-inputs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    @Test("Inputs cover agent logs but not app state that changes every few seconds")
    func inputsSelectUsageFilesOnly() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write("{}", to: home.appending(path: ".codex/sessions/2027/01/01/a.jsonl"))
        try Self.write("{}", to: home.appending(path: ".codex/.codex-global-state.json"))
        try Self.write("model = \"x\"", to: home.appending(path: ".codex/config.toml"))
        try Self.write("{}", to: home.appending(path: ".claude/projects/p/s.jsonl"))
        try Self.write("{}", to: home.appending(path: ".local/share/opencode/storage/x.json"))

        let inputs = CCUsageInputMonitor.inputs(
            for: Self.invocation(),
            additionalDirectories: [],
            now: Self.now,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            home: home
        )

        let root = try #require(realpath(home.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(inputs.directories == [
            "\(root)/.claude/projects",
            "\(root)/.codex/sessions",
            "\(root)/.local/share/opencode"
        ])
        #expect(inputs.fileStamps.contains { $0.hasPrefix(home.path + "/.codex/config.toml|") && !$0.hasSuffix("|missing") })
        #expect(!inputs.directories.contains("\(root)/.codex"))
        #expect(inputs.reportDay == "2027-01-15")
        // Codex inputs form their own group, so its half can be reused alone.
        #expect(inputs.groups[.codex]?.directories == ["\(root)/.codex/sessions"])
        #expect(inputs.groups[.codex]?.fileStamps.contains {
            $0.hasPrefix(home.path + "/.codex/config.toml|")
        } == true)
        #expect(inputs.groups[.others]?.directories == [
            "\(root)/.claude/projects",
            "\(root)/.local/share/opencode"
        ])
        #expect(inputs.groups[.others]?.fileStamps.contains { $0.contains("/.codex/") } == false)
    }

    @Test("A new agent directory, a config edit or a new day changes the inputs")
    func inputsTrackTopologyConfigurationAndDay() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: ".codex/config.toml")
        try Self.write("a", to: config)
        func inputs(at date: Date = Self.now) -> CCUsageInputMonitor.Inputs {
            CCUsageInputMonitor.inputs(
                for: Self.invocation(),
                additionalDirectories: [],
                now: date,
                timeZone: TimeZone(identifier: "UTC")!,
                home: home
            )
        }
        let original = inputs()
        #expect(inputs() == original)

        try Self.write("{}", to: home.appending(path: ".gemini/tmp/chat.json"))
        let withGemini = inputs()
        #expect(withGemini != original)

        try Self.write("a longer value", to: config)
        #expect(inputs() != withGemini)

        #expect(inputs(at: Self.now.addingTimeInterval(86_400)) != inputs())
    }

    @Test("Environment overrides and configured Claude directories are watched")
    func overridesAreWatched() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appending(path: "custom-codex", directoryHint: .isDirectory)
        let qwen = home.appending(path: "qwen-data", directoryHint: .isDirectory)
        let desktopClaude = home.appending(path: "desktop/.claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: codexHome.appending(path: "archived_sessions"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: qwen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: desktopClaude.appending(path: "projects"),
            withIntermediateDirectories: true
        )

        let inputs = CCUsageInputMonitor.inputs(
            for: Self.invocation(
                claudeDirectories: [desktopClaude],
                environment: ["CODEX_HOME": codexHome.path, "QWEN_DATA_DIR": qwen.path]
            ),
            additionalDirectories: [],
            now: Self.now,
            home: home
        )
        let directories = inputs.directories.joined(separator: "\n")
        #expect(directories.contains("custom-codex/archived_sessions"))
        #expect(directories.contains("qwen-data"))
        #expect(directories.contains("desktop/.claude/projects"))
    }

    private static func fixedInputs(
        day: String = "2027-01-15",
        codexStamp: String = "codex|1",
        othersStamp: String = "others|1"
    ) -> CCUsageInputMonitor.Inputs {
        CCUsageInputMonitor.Inputs(
            reportDay: day,
            timeZoneIdentifier: "UTC",
            arguments: ["daily"],
            sharedFileStamps: [],
            groups: [
                .codex: .init(directories: [], fileStamps: [codexStamp]),
                .others: .init(directories: [], fileStamps: [othersStamp])
            ]
        )
    }

    @Test("Only an unchanged, successful and recent run is reused")
    func reuseRules() {
        let monitor = CCUsageInputMonitor(startsEventStreams: false)
        let inputs = Self.fixedInputs()
        let other = Self.fixedInputs(day: "2027-01-16")
        #expect(!monitor.canReuseLastRun(for: inputs, at: Self.now))

        monitor.runWillStart(with: inputs, at: Self.now)
        // Still running: nothing to reuse yet.
        #expect(!monitor.canReuseLastRun(for: inputs, at: Self.now))
        monitor.runDidFinish(succeeded: true)
        #expect(monitor.canReuseLastRun(for: inputs, at: Self.now.addingTimeInterval(60)))
        #expect(!monitor.canReuseLastRun(for: other, at: Self.now.addingTimeInterval(60)))
        #expect(!monitor.canReuseLastRun(
            for: inputs,
            at: Self.now.addingTimeInterval(CCUsageInputMonitor.maximumReuseAge)
        ))
        #expect(!monitor.canReuseLastRun(for: inputs, at: Self.now.addingTimeInterval(-1)))

        monitor.markInputsChanged()
        #expect(!monitor.canReuseLastRun(for: inputs, at: Self.now.addingTimeInterval(60)))

        monitor.runWillStart(with: inputs, at: Self.now)
        monitor.runDidFinish(succeeded: false)
        #expect(!monitor.canReuseLastRun(for: inputs, at: Self.now.addingTimeInterval(60)))
    }

    @Test("Codex and the other agents are reused and invalidated separately")
    func groupsReuseSeparately() {
        let monitor = CCUsageInputMonitor(startsEventStreams: false)
        let inputs = Self.fixedInputs()
        monitor.runWillStart(with: inputs, at: Self.now)
        monitor.runDidFinish(succeeded: true)
        #expect(monitor.changedGroups(for: inputs, at: Self.now.addingTimeInterval(60)).isEmpty)

        // A new Claude session only reruns the cheap half.
        let othersChanged = Self.fixedInputs(othersStamp: "others|2")
        #expect(monitor.changedGroups(for: othersChanged, at: Self.now.addingTimeInterval(60)) == [.others])
        monitor.runWillStart(groups: [.others], with: othersChanged, at: Self.now.addingTimeInterval(60))
        monitor.runDidFinish(groups: [.others], succeeded: true)
        #expect(monitor.changedGroups(for: othersChanged, at: Self.now.addingTimeInterval(120)).isEmpty)

        // The reused Codex half still ages from its own run.
        #expect(monitor.changedGroups(
            for: othersChanged,
            at: Self.now.addingTimeInterval(CCUsageInputMonitor.maximumReuseAge + 30)
        ) == [.codex])

        monitor.markInputsChanged([.codex])
        #expect(monitor.changedGroups(for: othersChanged, at: Self.now.addingTimeInterval(120)) == [.codex])

        monitor.runWillStart(groups: [.codex], with: othersChanged, at: Self.now.addingTimeInterval(120))
        monitor.runDidFinish(groups: [.codex], succeeded: false)
        #expect(monitor.changedGroups(for: othersChanged, at: Self.now.addingTimeInterval(180)) == [.codex])
    }

    @Test("An event path is charged to its group; an unknown path to both")
    func eventPathGroups() {
        let roots: [(path: String, group: CCUsageInputMonitor.InputGroup)] = [
            (path: "/h/.codex/sessions", group: .codex),
            (path: "/h/.claude/projects", group: .others)
        ]
        #expect(CCUsageInputMonitor.groups(forEventPath: "/h/.codex/sessions/2027/a.jsonl", roots: roots) == [.codex])
        #expect(CCUsageInputMonitor.groups(forEventPath: "/h/.claude/projects/p/s.jsonl", roots: roots) == [.others])
        #expect(CCUsageInputMonitor.groups(forEventPath: "/h/.codex/sessions", roots: roots) == [.codex])
        // A sibling that only shares a prefix is not inside the root.
        #expect(CCUsageInputMonitor.groups(forEventPath: "/h/.codex/sessions-old/x", roots: roots) == [.codex, .others])
        #expect(CCUsageInputMonitor.groups(forEventPath: "", roots: roots) == [.codex, .others])
    }

    @Test("A write under a watched directory invalidates the last run")
    func fileSystemEventInvalidates() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let projects = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        // A WAL database keeps its shared-memory index next to it while open.
        let sharedMemoryIndex = sessions.appending(path: "history.db-shm")
        try Self.write("index", to: sharedMemoryIndex)
        let monitor = CCUsageInputMonitor()
        let inputs = CCUsageInputMonitor.inputs(
            for: Self.invocation(),
            additionalDirectories: [],
            now: Self.now,
            home: home
        )
        #expect(inputs.directories.count == 2)
        // On a loaded machine, writes made just before a stream starts can be
        // delivered to it. In production that only costs one extra run; here
        // the fixture must be older than the stream.
        try await Task.sleep(for: .seconds(3))

        monitor.runWillStart(with: inputs, at: Self.now)
        monitor.runDidFinish(succeeded: true)

        // Opening a WAL database rewrites its shared-memory index even for a
        // pure read, which is what the helper itself does.
        let handle = try FileHandle(forWritingTo: sharedMemoryIndex)
        try handle.write(contentsOf: Data("reread".utf8))
        try handle.close()
        try await Task.sleep(for: .milliseconds(3_500))
        #expect(
            monitor.canReuseLastRun(for: inputs, at: Self.now.addingTimeInterval(1)),
            "Invalidated by \(monitor.lastInvalidatingEventDescription ?? "a non-event change")"
        )

        // A Codex write invalidates only the Codex half.
        try Self.write("{}", to: sessions.appending(path: "new.jsonl"))
        var changed: Set<CCUsageInputMonitor.InputGroup> = []
        for _ in 0..<80 where changed.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            changed = monitor.changedGroups(for: inputs, at: Self.now.addingTimeInterval(1))
        }
        #expect(changed == [.codex])

        // The stream keeps watching the other half after the first change.
        try Self.write("{}", to: projects.appending(path: "p/s.jsonl"))
        for _ in 0..<80 where changed.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
            changed = monitor.changedGroups(for: inputs, at: Self.now.addingTimeInterval(1))
        }
        #expect(changed == [.codex, .others])
    }

    @Test("Only SQLite shared-memory index events are ignored")
    func eventClassification() {
        let none = FSEventStreamEventFlags(kFSEventStreamEventFlagNone)
        #expect(!CCUsageInputMonitor.eventChangesInputs(path: "/a/conv.db-shm", flags: none))
        #expect(CCUsageInputMonitor.eventChangesInputs(path: "/a/conv.db-wal", flags: none))
        #expect(CCUsageInputMonitor.eventChangesInputs(path: "/a/conv.db", flags: none))
        #expect(CCUsageInputMonitor.eventChangesInputs(path: "/a/s.jsonl", flags: none))
        #expect(CCUsageInputMonitor.eventChangesInputs(path: "", flags: none))
        // Dropped or coalesced history always reruns, whatever the path.
        #expect(CCUsageInputMonitor.eventChangesInputs(
            path: "/a/conv.db-shm",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        ))
    }

    @Test("Every data-directory variable in the vendored helper is covered")
    func vendoredHelperVariablesAreCovered() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil
        ) as? [String: Any]
        let helperVersion = try #require(info?["TokenRemainBundledCCUsageVersion"] as? String)
        let binary = try Data(contentsOf: root.appending(
            path: "Vendor/ccusage/\(helperVersion)/darwin-universal/ccusage"
        ))
        let found = Self.pathVariables(in: binary)
        // Guards the extraction itself, so an empty scan cannot pass.
        #expect(found.contains("CODEX_HOME"))
        #expect(found.contains("CLAUDE_CONFIG_DIR"))
        let uncovered = found.subtracting(CCUsageInputMonitor.recognizedEnvironmentVariables)
        #expect(
            uncovered.isEmpty,
            "Map these ccusage inputs in CCUsageInputMonitor: \(uncovered.sorted())"
        )
    }

    /// Names such as `CODEX_HOME` or `GOOSE_PATH_ROOT`. Adjacent string
    /// constants are packed without separators, so a run is split wherever one
    /// name ends and an uppercase letter starts the next.
    private static func pathVariables(in data: Data) -> Set<String> {
        let suffixes = ["_HOME", "_DIR", "_ROOT", "_PATH"]
        var names = Set<String>()
        var token: [UInt8] = []
        func flush() {
            var text = String(decoding: token, as: UTF8.self)
            token.removeAll(keepingCapacity: true)
            while !text.isEmpty {
                var split: String.Index?
                for suffix in suffixes {
                    var searchStart = text.startIndex
                    while let range = text.range(of: suffix, range: searchStart..<text.endIndex) {
                        let rest = text[range.upperBound...]
                        if rest.isEmpty || rest.first?.isUppercase == true {
                            if split.map({ range.upperBound < $0 }) ?? true {
                                split = range.upperBound
                            }
                            break
                        }
                        searchStart = range.upperBound
                    }
                }
                guard let split else { break }
                let name = String(text[..<split])
                if name.first?.isUppercase == true, name.contains("_") {
                    names.insert(name)
                }
                text = String(text[split...])
            }
        }
        for byte in data {
            let isNameByte = (65...90).contains(byte) || (48...57).contains(byte) || byte == 95
            if isNameByte {
                token.append(byte)
            } else if !token.isEmpty {
                flush()
            }
        }
        if !token.isEmpty { flush() }
        return names
    }
}
