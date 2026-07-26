import Foundation
import Testing
@testable import UsageDock

@Suite("ccusage update checker")
struct CCUsageUpdateCheckerTests {
    @Test("Official npm package metadata is parsed without reading usage logs")
    func parsesRegistryMetadata() throws {
        let data = Data(#"{"name":"@ccusage/ccusage-darwin-arm64","version":"20.0.18"}"#.utf8)
        let metadata = try CCUsageUpdateChecker.parseMetadata(data)

        #expect(metadata.name == CCUsageUpdateChecker.packageName)
        #expect(metadata.version == "20.0.18")
    }

    @Test("Semantic versions compare numerically")
    func comparesVersions() {
        #expect(CCUsageUpdateChecker.isNewer("20.0.19", than: "20.0.18"))
        #expect(CCUsageUpdateChecker.isNewer("20.1.0", than: "20.0.99"))
        #expect(!CCUsageUpdateChecker.isNewer("20.0.18", than: "20.0.18"))
        #expect(!CCUsageUpdateChecker.isNewer("19.9.9", than: "20.0.18"))
        #expect(CCUsageUpdateChecker.isNewer("20.0.18", than: "20.0.18-beta.1"))
    }

    @Test("Update status exposes whether the signed helper needs replacement")
    func exposesUpdateRequirement() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(!CCUsageUpdateStatus.current(
            installedVersion: "20.0.18",
            checkedAt: now
        ).needsUpdate)
        #expect(CCUsageUpdateStatus.updateAvailable(
            installedVersion: "20.0.18",
            latestVersion: "20.0.19",
            checkedAt: now
        ).needsUpdate)
    }
}
