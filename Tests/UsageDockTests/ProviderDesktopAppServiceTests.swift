import Foundation
import Testing
@testable import UsageDock

@Suite("Provider desktop app service")
struct ProviderDesktopAppServiceTests {
    @Test("Finds Claude and prefers current ChatGPT over legacy Codex")
    func findsSupportedApps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagedock-provider-apps-\(UUID().uuidString)", isDirectory: true)
        let applications = root.appending(path: "Applications")
        for name in ["Claude.app", "ChatGPT.app", "Codex.app"] {
            try FileManager.default.createDirectory(
                at: applications.appending(path: name),
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            ProviderDesktopAppService.applicationURL(
                for: .claude,
                home: root,
                applicationDirectories: [applications]
            )?.lastPathComponent == "Claude.app"
        )
        #expect(
            ProviderDesktopAppService.applicationURL(
                for: .codex,
                home: root,
                applicationDirectories: [applications]
            )?.lastPathComponent == "ChatGPT.app"
        )
        #expect(
            ProviderDesktopAppService.applicationURL(
                for: .cursor,
                home: root,
                applicationDirectories: [applications]
            ) == nil
        )
    }
}
