import AppKit
import XCTest
@testable import UsageDock

final class TokenRemainLogoTests: XCTestCase {
    func testDockRenderKeyDistinguishesProviderIdentityAndPresence() {
        // Claude 单条与 Codex 单条颜色不同,同档位也必须是不同的 key;
        // key 相同则跳过 Dock 重绘,混淆会让图标停在另一家的颜色上。
        XCTAssertNotEqual(
            TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: 45, codexRemaining: nil),
            TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: nil, codexRemaining: 45)
        )
        // 双条与单条、无数据分别可区分。
        XCTAssertNotEqual(
            TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: 45, codexRemaining: 45),
            TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: 45, codexRemaining: nil)
        )
        XCTAssertNotEqual(
            TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: nil, codexRemaining: nil),
            TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: 45, codexRemaining: nil)
        )
        // 相同输入必须稳定,内容去重才有意义。
        XCTAssertEqual(
            TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: 45, codexRemaining: 12),
            TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: 45, codexRemaining: 12)
        )
    }

    func testLiveSecondCountdownOnlyInsideTheFinalHour() {
        let now = Date(timeIntervalSince1970: 1_784_966_400)
        // 已过期的重置时间必须走静态展示,不允许钉住秒级刷新。
        XCTAssertFalse(UsageFormatting.showsLiveSecondCountdown(to: now.addingTimeInterval(-5), now: now))
        XCTAssertFalse(UsageFormatting.showsLiveSecondCountdown(to: now, now: now))
        XCTAssertTrue(UsageFormatting.showsLiveSecondCountdown(to: now.addingTimeInterval(1_800), now: now))
        XCTAssertTrue(UsageFormatting.showsLiveSecondCountdown(to: now.addingTimeInterval(3_599), now: now))
        XCTAssertFalse(UsageFormatting.showsLiveSecondCountdown(to: now.addingTimeInterval(3_600), now: now))
        XCTAssertFalse(UsageFormatting.showsLiveSecondCountdown(to: now.addingTimeInterval(7_200), now: now))
    }

    func testMenuBarKeepsEveryConfiguredTrackedProviderInUserOrder() {
        let providers = StatusBarPresentation.visibleProviders(
            configured: [.claude, .codex, .cursor],
            tracked: [.claude, .codex]
        )

        XCTAssertEqual(providers, [.claude, .codex])
    }

    func testMenuBarModesKeepSelectionUnlessMinimalWasExplicitlyChosen() {
        let selected: [ProviderQuota.Provider] = [.claude, .codex]
        let remaining: [ProviderQuota.Provider: Double] = [.claude: 99, .codex: 52]

        XCTAssertEqual(
            StatusBarPresentation.displayedProviders(
                mode: .full,
                selected: selected,
                remainingPercent: remaining
            ),
            selected
        )
        XCTAssertEqual(
            StatusBarPresentation.displayedProviders(
                mode: .compact,
                selected: selected,
                remainingPercent: remaining
            ),
            selected
        )
        XCTAssertEqual(
            StatusBarPresentation.displayedProviders(
                mode: .minimal,
                selected: selected,
                remainingPercent: remaining
            ),
            [.codex]
        )
    }

    func testMenuBarSummaryUsesTightestGeneralWindowAndIgnoresFableQuota() {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 29, windowMinutes: 10_080, resetsAt: nil),
            planName: nil,
            capturedAt: .now,
            scopedWindows: [
                ScopedQuotaWindow(
                    scopeID: "fable",
                    displayName: "Fable",
                    window: QuotaWindow(usedPercent: 88, windowMinutes: 10_080, resetsAt: nil)
                )
            ]
        )

        XCTAssertEqual(
            StatusBarPresentation.headlineRemainingPercent(in: claude),
            71
        )
        XCTAssertEqual(
            StatusBarPresentation.remainingText(for: claude),
            "71%"
        )
        XCTAssertEqual(
            StatusBarPresentation.tooltipProviderLabel(.claude, quota: claude),
            "Claude · \(UsageFormatting.windowName(minutes: 10_080))"
        )
    }

    func testMenuBarShowsMonetaryBalanceInsteadOfAvailabilityPercent() {
        let deepSeek = ProviderQuota(
            provider: .deepseek,
            primary: QuotaWindow(usedPercent: 0, windowMinutes: 0, resetsAt: nil),
            secondary: nil,
            planName: "Balance ¥90.56",
            capturedAt: .now,
            remainingBalance: QuotaBalance(amount: 90.56, currencyCode: "CNY")
        )

        XCTAssertEqual(StatusBarPresentation.headlineRemainingPercent(in: deepSeek), 100)
        XCTAssertEqual(StatusBarPresentation.remainingText(for: deepSeek), "¥90.56")
    }

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
    func testDockLogoComparesEachProvidersTightestGeneralWindow() {
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
        XCTAssertEqual(selection?.provider, .claude)
        XCTAssertEqual(selection?.windowMinutes, 10_080)
        XCTAssertEqual(selection?.remainingPercent, 15)
        XCTAssertEqual(UsageStore.aggregateRemainingPercent(from: [claude, codex]), 15)
    }

    @MainActor
    func testDockLogoUsesTightestWindowEvenWhenItIsSecondary() {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 92, windowMinutes: 300, resetsAt: nil),
            planName: nil,
            capturedAt: .now
        )

        let selection = UsageStore.logoQuotaSelection(from: [claude])
        XCTAssertEqual(selection?.windowMinutes, 300)
        XCTAssertEqual(selection?.remainingPercent, 8)
    }
}
