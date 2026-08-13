import AppKit
import SwiftUI
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

@Suite("Menu bar popup sizing")
struct MenuBarPopupSizingTests {
    @Test("Resolved menu height includes the popup beak exactly once")
    func includesChromeHeight() {
        let size = MenuBarPopupSizing.contentSize(forMenuHeight: 700)

        #expect(size == NSSize(width: 380, height: 711))
    }

    @Test("Invalid measurements cannot resize the AppKit window")
    func rejectsInvalidMeasurements() {
        #expect(MenuBarPopupSizing.contentSize(forMenuHeight: 0) == nil)
        #expect(MenuBarPopupSizing.contentSize(forMenuHeight: -.infinity) == nil)
        #expect(MenuBarPopupSizing.contentSize(forMenuHeight: .nan) == nil)
    }

    @Test("Subpixel measurement noise does not trigger another window layout")
    func resizeIsIdempotent() {
        let current = NSSize(width: 380, height: 711)

        #expect(!MenuBarPopupSizing.requiresResize(from: current, to: current))
        #expect(!MenuBarPopupSizing.requiresResize(
            from: current,
            to: NSSize(width: 380.25, height: 710.75)
        ))
        #expect(MenuBarPopupSizing.requiresResize(
            from: current,
            to: NSSize(width: 380, height: 712)
        ))
    }
}

@Suite("Fixed AppKit hosting window sizing")
@MainActor
struct FixedHostingWindowSizingTests {
    @Test("SwiftUI cannot feed content-derived constraints back into the window")
    func disablesAutomaticSizing() {
        let hosting = NSHostingController(rootView: Text("TokenRemain"))

        FixedHostingWindowSizing.configure(hosting)

        #expect(hosting.sizingOptions.isEmpty)
    }
}

/// The shell and the beak are one closed path, which is what lets the backdrop
/// glass, the clip and the rim describe exactly the same edge. These guard the
/// properties that a second, separately drawn triangle used to violate.
@Suite("Menu bar popup shell shape")
struct MenuBarPopupShellShapeTests {
    private let bounds = CGRect(x: 0, y: 0, width: 380, height: 700)

    private func shape(beakCenterX: CGFloat = 190) -> MenuBarPopupShellShape {
        MenuBarPopupShellShape(beakCenterX: beakCenterX)
    }

    @Test("The silhouette is one path spanning shell and beak")
    func unifiedSilhouette() {
        let path = shape().path(in: bounds)
        let box = path.boundingRect

        #expect(!path.isEmpty)
        #expect(abs(box.maxY - bounds.maxY) < 0.001)
        // The beak rises above the shell's top edge…
        #expect(box.minY < MenuBarPopupShellShape.beakOverhang)
        // …but its apex is filleted, so it is a rounded crest, not a spike.
        #expect(box.minY > bounds.minY)
        #expect(box.minY < 2)
    }

    @Test("Only the beak occupies the band above the shell body")
    func beakBandIsOtherwiseEmpty() {
        let path = shape().path(in: bounds)
        let aboveEdge = MenuBarPopupShellShape.beakOverhang - 3

        #expect(path.contains(CGPoint(x: 190, y: aboveEdge)))
        #expect(!path.contains(CGPoint(x: 60, y: aboveEdge)))
        #expect(!path.contains(CGPoint(x: 320, y: aboveEdge)))
        // Body corners stay rounded at the unchanged 14pt radius.
        #expect(!path.contains(CGPoint(x: 1, y: MenuBarPopupShellShape.beakOverhang + 1)))
        #expect(path.contains(CGPoint(x: 190, y: MenuBarPopupShellShape.beakOverhang + 1)))
    }

    @Test("The beak tracks its center and stays clear of the shell corners")
    func beakTracksCenter() {
        for centerX in stride(from: CGFloat(40), through: 340, by: 20) {
            let path = shape(beakCenterX: centerX).path(in: bounds)
            let aboveEdge = MenuBarPopupShellShape.beakOverhang - 3
            #expect(path.contains(CGPoint(x: centerX, y: aboveEdge)))
        }

        // Beyond the corners the beak is held back rather than drawn over the
        // rounded corner, so the silhouette never grows a bump on its side.
        for centerX in [CGFloat(-40), 0, 380, 420] {
            let path = shape(beakCenterX: centerX).path(in: bounds)
            #expect(path.boundingRect.minX >= bounds.minX)
            #expect(path.boundingRect.maxX <= bounds.maxX)
            #expect(path.boundingRect.minY < MenuBarPopupShellShape.beakOverhang)
        }
    }

    @Test("Insetting keeps the rim inside the silhouette it strokes")
    func insetStaysInside() {
        let outer = shape().path(in: bounds)
        let inner = shape().inset(by: 0.5).path(in: bounds)

        #expect(inner.boundingRect.minX > outer.boundingRect.minX)
        #expect(inner.boundingRect.maxX < outer.boundingRect.maxX)
        #expect(inner.boundingRect.minY > outer.boundingRect.minY)
        #expect(inner.boundingRect.maxY < outer.boundingRect.maxY)
        // Still one continuous silhouette, beak included.
        #expect(inner.contains(CGPoint(x: 190, y: MenuBarPopupShellShape.beakOverhang - 3)))
    }
}
