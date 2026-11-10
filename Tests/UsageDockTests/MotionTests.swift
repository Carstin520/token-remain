import CoreGraphics
import SwiftUI
import Testing
@testable import UsageDock

@Suite("Motion")
struct MotionTests {
    @Test("A quota bar or figure plays on first appearance and each time the page is revealed")
    func quotaEntranceRule() {
        // A Dashboard page: revealed from the start, so it plays on appearing.
        #expect(QuotaEntrance.next(previous: nil, revealed: true, animates: true) == .play)
        #expect(QuotaEntrance.next(previous: true, revealed: true, animates: true) == nil)
        // The popup: zeros while closed, plays on every opening.
        #expect(QuotaEntrance.next(previous: nil, revealed: false, animates: true) == .zero)
        #expect(QuotaEntrance.next(previous: false, revealed: true, animates: true) == .play)
        #expect(QuotaEntrance.next(previous: true, revealed: false, animates: true) == .zero)
        // Reduce Motion: the value, never zeros or motion.
        #expect(QuotaEntrance.next(previous: nil, revealed: false, animates: false) == .still)
        #expect(QuotaEntrance.next(previous: false, revealed: true, animates: false) == .still)
        #expect(QuotaEntrance.next(previous: true, revealed: true, animates: false) == nil)
    }

    @Test("Odometer columns split digits from the text around them")
    func odometerSegments() {
        #expect(RollingFigure.segments("$94.50") == [.run("$"), .digit(9), .digit(4), .run("."), .digit(5), .digit(0)])
        #expect(RollingFigure.segments("98% remaining") == [.digit(9), .digit(8), .run("% remaining")])
        #expect(RollingFigure.segments("Used up") == [.run("Used up")])
        #expect(RollingFigure.segments("") == [])
    }

    @Test("The detail shield answers only the zero-size minimum query itself")
    func minimumSizeShieldQuery() {
        #expect(MinimumSizeShieldLayout.isMinimumQuery(ProposedViewSize(width: 0, height: 0)))
        #expect(MinimumSizeShieldLayout.isMinimumQuery(ProposedViewSize(width: 0, height: nil)))
        #expect(!MinimumSizeShieldLayout.isMinimumQuery(ProposedViewSize(width: 900, height: 700)))
        #expect(!MinimumSizeShieldLayout.isMinimumQuery(.unspecified))
    }

    @Test("Overview cards sit side by side from the row width, stacked below it")
    func adaptiveRowThreshold() {
        #expect(AdaptiveRowLayout.isRow(width: 640, minimum: 640))
        #expect(AdaptiveRowLayout.isRow(width: 1100, minimum: 640))
        #expect(!AdaptiveRowLayout.isRow(width: 639, minimum: 640))
    }

    @Test("The Dashboard animates in only when it was not already on screen")
    func dashboardOpenRule() {
        #expect(DashboardWindowController.opensWithAnimation(wasOnScreen: false, reduceMotion: false))
        #expect(!DashboardWindowController.opensWithAnimation(wasOnScreen: true, reduceMotion: false))
        #expect(!DashboardWindowController.opensWithAnimation(wasOnScreen: false, reduceMotion: true))
        #expect(MotionTiming.dashboardFadeIn > MotionTiming.popupFadeIn)
    }

    @Test("A ripple reaches the farthest corner from where it starts")
    func rippleCoversButton() {
        let size = CGSize(width: 200, height: 40)
        #expect(MotionGeometry.rippleReach(from: .zero, in: size) == hypot(200, 40))
        #expect(MotionGeometry.rippleReach(from: CGPoint(x: 100, y: 20), in: size) == hypot(100, 20))
        #expect(MotionGeometry.rippleReach(from: CGPoint(x: 190, y: 20), in: size) == hypot(190, 20))
    }

    @Test("The switch keeps the system switch's footprint per control size")
    func switchFootprint() {
        #expect(MotionGeometry.switchTrack(for: .small) == CGSize(width: 32, height: 18))
        #expect(MotionGeometry.switchTrack(for: .regular) == CGSize(width: 40, height: 22))
        #expect(MotionGeometry.switchTrack(for: .mini) == CGSize(width: 26, height: 15))
    }
}
