import Testing
@testable import UsageDock

@MainActor
@Suite("Dashboard visibility transitions")
struct DashboardVisibilityTests {
    @Test("Only a hidden-to-visible edge requests catch-up work")
    func visibleEdges() {
        let visibility = DashboardVisibility()

        #expect(!visibility.setVisible(false))
        #expect(visibility.setVisible(true))
        #expect(!visibility.setVisible(true))
        #expect(!visibility.setVisible(false))
        #expect(visibility.setVisible(true))
    }
}
