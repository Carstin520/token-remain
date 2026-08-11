import AppKit
import Testing
@testable import UsageDock

@Suite("Menu bar popup placement")
struct MenuBarPopupPlacementTests {
    @Test("Popup is centered below the status item and the arrow tracks its center")
    func centeredAlignment() {
        let placement = MenuBarPopupPlacement.resolve(
            anchorFrame: NSRect(x: 700, y: 876, width: 80, height: 24),
            popupSize: NSSize(width: 380, height: 700),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 876)
        )

        #expect(placement.origin == NSPoint(x: 550, y: 176))
        #expect(placement.arrowCenterX == 190)
    }

    @Test("Screen clamping moves the popup while its arrow keeps pointing at the status item")
    func clampedArrowAlignment() {
        let placement = MenuBarPopupPlacement.resolve(
            anchorFrame: NSRect(x: 1400, y: 876, width: 80, height: 24),
            popupSize: NSSize(width: 380, height: 700),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 876)
        )

        #expect(placement.origin == NSPoint(x: 1132, y: 176))
        #expect(placement.arrowCenterX == 308)
    }

    @Test("Popup stays inside the screen at either horizontal edge")
    func clampsToVisibleFrame() {
        let visibleFrame = NSRect(x: 100, y: 40, width: 1000, height: 700)
        let size = NSSize(width: 380, height: 760)
        let leftPlacement = MenuBarPopupPlacement.resolve(
            anchorFrame: NSRect(x: 80, y: 720, width: 30, height: 20),
            popupSize: size,
            visibleFrame: visibleFrame
        )
        let rightPlacement = MenuBarPopupPlacement.resolve(
            anchorFrame: NSRect(x: 1090, y: 720, width: 30, height: 20),
            popupSize: size,
            visibleFrame: visibleFrame
        )

        #expect(leftPlacement.origin == NSPoint(x: 100, y: 40))
        #expect(leftPlacement.arrowCenterX == 16)
        #expect(rightPlacement.origin == NSPoint(x: 720, y: 40))
        #expect(rightPlacement.arrowCenterX == 364)
    }
}
