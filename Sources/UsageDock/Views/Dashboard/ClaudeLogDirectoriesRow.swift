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
            ForEach(directories, id: \.path) { directory in
                HStack(alignment: .top) {
                    Text(directory.path).font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if custom.contains(directory.path) {
                        Button(L10n.text("action.remove")) {
                            custom.removeAll { $0 == directory.path }
                            persist()
                        }.buttonStyle(.plain)
                    }
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

    private func persist() {
        UserDefaults.standard.set(custom, forKey: ClaudeLogDirectories.defaultsKey)
        store.refreshLocalUsage()
    }
}
