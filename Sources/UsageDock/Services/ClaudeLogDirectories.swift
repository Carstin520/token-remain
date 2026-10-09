import Foundation

/// Only discovers directories. Usage records and their cross-directory deduplication
/// remain the responsibility of the bundled, offline ccusage helper.
enum ClaudeLogDirectories {
    static let defaultsKey = "claude.localLogDirectories.v1"

    static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        additional: [String] = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [],
        maximumEntries: Int = 10_000
    ) throws -> [URL] {
        let fm = FileManager.default
        var candidates = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".config/claude")]
        candidates += (environment["CLAUDE_CONFIG_DIR"] ?? "").split(separator: ",").map {
            URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        candidates += additional.map { URL(fileURLWithPath: $0) }
        let base = home.appendingPathComponent("Library/Application Support/Claude")
        var visited = 0
        for name in ["local-agent-mode-sessions", "claude-code-sessions"] {
            let root = base.appendingPathComponent(name)
            guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                              options: [.skipsPackageDescendants]) else { continue }
            while let url = entries.nextObject() as? URL {
                try Task.checkCancellation()
                visited += 1
                guard visited <= maximumEntries else { throw DiscoveryError.limitReached }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { entries.skipDescendants(); continue }
                if url.lastPathComponent == ".claude", values?.isDirectory == true {
                    candidates.append(url)
                    entries.skipDescendants()
                } else if entries.level >= 4 { entries.skipDescendants() }
            }
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.appendingPathComponent("projects").path, isDirectory: &isDirectory),
                  isDirectory.boolValue, !url.path.contains(","), seen.insert(url.path).inserted else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    enum DiscoveryError: LocalizedError {
        case limitReached
        var errorDescription: String? { L10n.text("claude.logs.scan_limit") }
    }
}
