import AppKit
import Foundation

/// Claude/Codex 登录与 token 续期仍由官方桌面应用负责。TokenRemain 只在
/// 用户明确点击时打开已安装应用,不会在后台自动启动其他进程。
struct ProviderDesktopAppService {
    static func applicationURL(
        for provider: ProviderQuota.Provider,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil
    ) -> URL? {
        let directories = applicationDirectories ?? [
            home.appending(path: "Applications"),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]
        let names: [String]
        switch provider {
        case .claude:
            names = ["Claude.app"]
        case .codex:
            names = ["ChatGPT.app", "Codex.app"]
        default:
            return nil
        }
        let fileManager = FileManager.default
        for name in names {
            if let url = directories
                .map({ $0.appending(path: name) })
                .first(where: { fileManager.fileExists(atPath: $0.path) }) {
                return url
            }
        }
        return nil
    }

    @MainActor
    @discardableResult
    static func open(_ provider: ProviderQuota.Provider) -> Bool {
        guard let url = applicationURL(for: provider) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
