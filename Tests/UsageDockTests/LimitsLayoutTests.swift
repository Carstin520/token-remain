import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import UsageDock

@Suite("Limits grid layout")
struct LimitsLayoutTests {
    private func columns(_ width: CGFloat) -> Int {
        QuotaGridLayout.columnCount(
            forWidth: width,
            minimum: LimitsSection.columnMinimum,
            spacing: LimitsSection.columnSpacing
        )
    }

    @Test("Column count follows the adaptive grid's minimum width")
    func columnCount() {
        #expect(columns(0) == 1)
        #expect(columns(299) == 1)
        #expect(columns(614) == 2)
        #expect(columns(927) == 2)
        #expect(columns(928) == 3)
        #expect(columns(.infinity) == 1)
    }

    @Test("Columns share the width up to the maximum")
    func columnWidth() {
        #expect(QuotaGridLayout.columnWidth(forWidth: 614, columns: 2, maximum: 460, spacing: 14) == 300)
        #expect(QuotaGridLayout.columnWidth(forWidth: 800, columns: 2, maximum: 460, spacing: 14) == 393)
        #expect(QuotaGridLayout.columnWidth(forWidth: 1200, columns: 2, maximum: 460, spacing: 14) == 460)
        #expect(QuotaGridLayout.columnWidth(forWidth: 0, columns: 1, maximum: 460, spacing: 14) == 0)
    }

    @Test("Cards in one row share its tallest height; rows stay independent")
    func rowHeights() {
        let natural: [CGFloat] = [260, 340, 300, 410, 224, 224, 280]

        #expect(QuotaGridLayout.rowHeights(natural: natural, columns: 3) == [340, 410, 280])
        #expect(QuotaGridLayout.rowHeights(natural: natural, columns: 2) == [340, 410, 224, 280])
        #expect(QuotaGridLayout.rowHeights(natural: [], columns: 3).isEmpty)
    }

    @Test("Only content beyond the cap scrolls inside a card")
    func scrollThreshold() {
        #expect(!QuotaCard.contentScrolls(naturalContentHeight: 0))
        #expect(!QuotaCard.contentScrolls(naturalContentHeight: 380))
        #expect(!QuotaCard.contentScrolls(naturalContentHeight: QuotaCard.maximumContentHeight))
        #expect(QuotaCard.contentScrolls(naturalContentHeight: QuotaCard.maximumContentHeight + 40))
    }
}

/// Runs the grid through SwiftUI's real layout engine. The grid computes its
/// rows inside one layout pass, so a single fitting pass already yields the
/// final height; 1.4.7 (46) needed measured state to settle first and on some
/// dashboards it never did.
@Suite("Limits grid hosting")
@MainActor
struct LimitsGridHostingTests {
    private func fittingHeight(width: CGFloat, cells: [CGFloat]) -> CGFloat {
        let grid = QuotaGridLayout(
            minimumColumnWidth: LimitsSection.columnMinimum,
            maximumColumnWidth: LimitsSection.columnMaximum,
            spacing: LimitsSection.columnSpacing
        ) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, height in
                // A card's shape: natural height, then fills the row it is offered.
                Color.clear
                    .frame(height: height)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        let hosting = NSHostingView(rootView: grid.frame(width: width))
        return hosting.fittingSize.height
    }

    @Test("Rows take their tallest card and stack with the grid spacing")
    func rowsStack() {
        // 614 pt fits two columns: rows of max(100, 150) and max(120, 80).
        let twoColumns: CGFloat = 150 + 14 + 120
        #expect(fittingHeight(width: 614, cells: [100, 150, 120, 80]) == twoColumns)
        // 928 pt fits three: one row of max(100, 150, 120), then 80.
        let threeColumns: CGFloat = 150 + 14 + 80
        #expect(fittingHeight(width: 928, cells: [100, 150, 120, 80]) == threeColumns)
    }

    @Test("Stretchable cells do not inflate their own row")
    func stretchDoesNotFeedBack() {
        #expect(fittingHeight(width: 299, cells: [224]) == 224)
        #expect(fittingHeight(width: 614, cells: [224, 224]) == 224)
    }
}
