import CoreGraphics
import Testing
@testable import UsageDock

@Suite("Limits grid layout")
struct LimitsLayoutTests {
    @Test("Column count follows the adaptive grid's minimum width")
    func columnCount() {
        #expect(LimitsSection.columnCount(forWidth: 0) == 1)
        #expect(LimitsSection.columnCount(forWidth: 299) == 1)
        #expect(LimitsSection.columnCount(forWidth: 614) == 2)
        #expect(LimitsSection.columnCount(forWidth: 927) == 2)
        #expect(LimitsSection.columnCount(forWidth: 928) == 3)
    }

    @Test("Cards in one row share its tallest height; rows stay independent")
    func rowHeights() {
        let order: [ProviderQuota.Provider] = [.claude, .antigravity, .codex, .cursor, .deepseek, .grokBot, .muse]
        let natural: [ProviderQuota.Provider: CGFloat] = [
            .claude: 260, .antigravity: 340, .codex: 300,
            .cursor: 410, .deepseek: 224, .grokBot: 224,
            .muse: 280
        ]
        let heights = LimitsSection.rowHeights(order: order, natural: natural, columns: 3)

        #expect(heights[.claude] == 340)
        #expect(heights[.antigravity] == 340)
        #expect(heights[.codex] == 340)
        #expect(heights[.cursor] == 410)
        #expect(heights[.deepseek] == 410)
        #expect(heights[.grokBot] == 410)
        #expect(heights[.muse] == 280)

        let twoColumns = LimitsSection.rowHeights(order: order, natural: natural, columns: 2)
        #expect(twoColumns[.claude] == 340)
        #expect(twoColumns[.codex] == 410)
        #expect(twoColumns[.deepseek] == 224)
    }

    @Test("A card measured before others reports wait for theirs without collapsing the row")
    func missingMeasurements() {
        let heights = LimitsSection.rowHeights(order: [.claude, .codex], natural: [.codex: 300], columns: 2)
        #expect(heights[.claude] == 300)
        #expect(heights[.codex] == 300)
    }

    @Test("Only content beyond the cap scrolls inside a card")
    func scrollThreshold() {
        #expect(!QuotaCard.contentScrolls(naturalContentHeight: 0))
        #expect(!QuotaCard.contentScrolls(naturalContentHeight: 380))
        #expect(!QuotaCard.contentScrolls(naturalContentHeight: QuotaCard.maximumContentHeight))
        #expect(QuotaCard.contentScrolls(naturalContentHeight: QuotaCard.maximumContentHeight + 40))
    }
}
