import XCTest
@testable import UsageDock

final class TokenRemainLogoTests: XCTestCase {
    func testEmotionBandsCoverFullQuotaRange() {
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 100), .excitedStars)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 90), .happyCarets)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 80), .sparkle)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 70), .calmDots)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 60), .focusedBars)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 50), .neutralDashes)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 40), .worriedSlants)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 30), .tenseChevrons)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 20), .dizzySpirals)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 10), .cryingWarning)
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: 0), .offline)
    }

    func testUnknownQuotaUsesNeutralState() {
        XCTAssertEqual(TokenRemainLogoState.resolve(remainingPercent: nil), .neutralDashes)
    }

    @MainActor
    func testDockLogoUsesScarcestWindowAcrossProviders() {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 85, windowMinutes: 10_080, resetsAt: nil),
            planName: nil,
            capturedAt: .now
        )
        let codex = ProviderQuota(
            provider: .codex,
            primary: QuotaWindow(usedPercent: 54, windowMinutes: 10_080, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now
        )

        XCTAssertEqual(
            UsageStore.aggregateRemainingPercent(from: [claude, codex]),
            15
        )
    }
}
