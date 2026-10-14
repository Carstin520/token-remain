import SwiftUI
import UniformTypeIdentifiers

struct ClaudeLogDirectoriesRow: View {
    @ObservedObject var store: UsageStore
    @State private var directories: [URL] = []
    @State private var custom = UserDefaults.standard.stringArray(forKey: ClaudeLogDirectories.defaultsKey) ?? []
    @State private var choosing = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("claude.logs.title")).font(.system(size: 12, weight: .semibold))
            Text(L10n.text("claude.logs.note"))
                .font(.system(size: 11)).foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // Discovered folders are summarised, not listed: desktop Code and
            // Cowork sessions each bring their own `.claude` folder, and a wall
            // of session UUID paths tells the user nothing they can act on.
            // Only folders the user added are listed, so they can be removed,
            // including one that no longer exists.
            if let summary {
                Text(summary)
                    .font(.system(size: 11)).foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(custom, id: \.self) { path in
                HStack(alignment: .top) {
                    Text(Self.abbreviated(path)).font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(L10n.text("action.remove")) {
                        custom.removeAll { $0 == path }
                        persist()
                    }.buttonStyle(.plain)
                }
            }
            if directories.isEmpty { Text(L10n.text("claude.logs.empty")).font(.system(size: 11)) }
            if let notice { Text(notice).font(.system(size: 11)).foregroundStyle(DashboardTheme.warning) }
            Button(L10n.text("claude.logs.add")) { choosing = true }
        }
        .task(id: custom) {
            do {
                let paths = custom
                let result = try await AsyncDeadline.run(timeout: 5) { try ClaudeLogDirectories.discover(additional: paths) }
                try Task.checkCancellation()
                directories = result
                notice = nil
            } catch is CancellationError {} catch { notice = error.localizedDescription }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
                guard !normalized.path.contains(","),
                      FileManager.default.fileExists(atPath: normalized.appendingPathComponent("projects").path) else {
                    notice = L10n.text("claude.logs.empty")
                    continue
                }
                if !custom.contains(normalized.path) { custom.append(normalized.path) }
            }
            persist()
        }
    }

    private var summary: String? {
        let customPaths = Set(custom)
        let sessionRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude").standardizedFileURL.path + "/"
        let discovered = directories.filter { !customPaths.contains($0.path) }
        let sessions = discovered.filter { $0.path.hasPrefix(sessionRoot) }.count
        let readsCLI = discovered.count > sessions
        switch (readsCLI, sessions) {
        case (false, 0): return nil
        case (true, 0): return L10n.text("claude.logs.summary_cli")
        case (false, _): return L10n.format("claude.logs.summary_sessions", sessions)
        case (true, _): return L10n.format("claude.logs.summary_cli_and_sessions", sessions)
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func persist() {
        UserDefaults.standard.set(custom, forKey: ClaudeLogDirectories.defaultsKey)
        store.refreshLocalUsage()
    }
}
