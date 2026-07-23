import AppKit
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

    func testLogoToneUsesProviderIdentityUntilQuotaIsCritical() {
        XCTAssertEqual(
            TokenRemainLogoTone.resolve(provider: .claude, remainingPercent: 10),
            .provider(.claude)
        )
        XCTAssertEqual(
            TokenRemainLogoTone.resolve(provider: .codex, remainingPercent: 64),
            .provider(.codex)
        )
        XCTAssertEqual(
            TokenRemainLogoTone.resolve(provider: .claude, remainingPercent: 9.99),
            .critical
        )
        XCTAssertEqual(
            TokenRemainLogoTone.resolve(provider: nil, remainingPercent: nil),
            .neutral
        )
    }

    func testEveryQuotaStateKeepsItsOwnPixelFace() {
        XCTAssertEqual(PixelRobotMark.Face.allCases.count, 11)
        XCTAssertEqual(PixelRobotMark.face(for: .excitedStars), .excitedStars)
        XCTAssertEqual(PixelRobotMark.face(for: .calmDots), .calmDots)
        XCTAssertEqual(PixelRobotMark.face(for: .neutralDashes), .neutralDashes)
        XCTAssertEqual(PixelRobotMark.face(for: .cryingWarning), .cryingWarning)
        XCTAssertEqual(PixelRobotMark.face(for: .offline), .offline)
    }

    func testPixelRobotMatrixIsCompleteForEveryFace() {
        for face in PixelRobotMark.Face.allCases {
            let matrix = PixelRobotMark.matrix(face: face)
            XCTAssertEqual(matrix.count, PixelRobotMark.rows)
            XCTAssertTrue(matrix.allSatisfy { $0.count == PixelRobotMark.columns })
        }
    }

    func testPixelRobotUsesCanonicalOrbitSilhouette() {
        let matrix = PixelRobotMark.matrix(face: .neutralDashes)
        XCTAssertEqual(PixelRobotMark.columns, 16)
        XCTAssertEqual(PixelRobotMark.rows, 16)
        XCTAssertEqual(matrix[0][7], .cap)
        XCTAssertEqual(matrix[7][0], .signal)
        XCTAssertEqual(matrix[7][1], .body)
        XCTAssertEqual(matrix[14][4], .bodyDim)
        XCTAssertEqual(matrix[15][5], .empty)
    }

    func testDockLogoQuotaMeterUsesTheActualRemainingPercent() {
        XCTAssertNil(TokenRemainLogoMeter.filledSegments(remainingPercent: nil))
        XCTAssertEqual(TokenRemainLogoMeter.filledSegments(remainingPercent: 0), 0)
        XCTAssertEqual(TokenRemainLogoMeter.filledSegments(remainingPercent: 45), 5)
        XCTAssertEqual(TokenRemainLogoMeter.filledSegments(remainingPercent: 100), 10)
    }

    func testDockLogoKeepsRasterArtworkUpright() throws {
        let size = NSSize(width: 32, height: 32)
        let source = NSImage(size: size, flipped: false) { rect in
            NSColor.blue.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2).fill()
            NSColor.red.setFill()
            NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2).fill()
            return true
        }
        let rendered = TokenRemainHeadLogoArtwork.renderSourceUprightForTesting(
            source,
            size: size.width
        )

        let sourceData = try XCTUnwrap(source.tiffRepresentation)
        let sourceBitmap = try XCTUnwrap(NSBitmapImageRep(data: sourceData))
        let renderedData = try XCTUnwrap(rendered.tiffRepresentation)
        let renderedBitmap = try XCTUnwrap(NSBitmapImageRep(data: renderedData))

        for y in [8, 24] {
            let expected = try XCTUnwrap(
                sourceBitmap.colorAt(x: 16, y: y)?.usingColorSpace(.deviceRGB)
            )
            let actual = try XCTUnwrap(
                renderedBitmap.colorAt(x: 16, y: y)?.usingColorSpace(.deviceRGB)
            )
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.08)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.08)
        }
    }

    @MainActor
    func testDockLogoComparesEachProvidersShortestAvailableSession() {
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

        let selection = UsageStore.logoQuotaSelection(from: [claude, codex])
        XCTAssertEqual(selection?.provider, .codex)
        XCTAssertEqual(selection?.windowMinutes, 10_080)
        XCTAssertEqual(selection?.remainingPercent, 46)
        XCTAssertEqual(UsageStore.aggregateRemainingPercent(from: [claude, codex]), 46)
    }

    @MainActor
    func testDockLogoUsesShortestWindowEvenWhenItIsSecondary() {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 92, windowMinutes: 10_080, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil),
            planName: nil,
            capturedAt: .now
        )

        let selection = UsageStore.logoQuotaSelection(from: [claude])
        XCTAssertEqual(selection?.windowMinutes, 300)
        XCTAssertEqual(selection?.remainingPercent, 80)
    }
}
