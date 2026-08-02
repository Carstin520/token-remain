import Testing
@testable import UsageDock

@Suite("Dashboard settings navigation")
struct SettingsNavigationTests {
    @Test("Preferences stay grouped under a stable second-level hierarchy")
    func categoryHierarchy() {
        let categories = SettingsCategory.allCases

        #expect(categories.map(\.rawValue) == ["general", "menuBar", "refreshAndSync", "about"])
        #expect(categories.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        #expect(Set(categories.map(\.systemImage)).count == categories.count)
    }
}
