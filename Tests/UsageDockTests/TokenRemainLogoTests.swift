import AppKit
import XCTest
@testable import UsageDock

final class TokenRemainLogoTests: XCTestCase {
    func testDockRenderKeyDependsOnDotsAndMissingState() {
        let key: (Double?, Double?) -> String = { TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: $0, codexRemaining: $1) }
        XCTAssertEqual(key(45, nil), key(nil, 45))
        XCTAssertEqual(key(45, 45), key(45, nil))
        XCTAssertNotEqual(key(nil, nil), key(0, nil))
        XCTAssertNotEqual(key(nil, nil), key(45, nil))
        XCTAssertEqual(key(45, 12), key(45, 12))
        XCTAssertEqual(key(20, 100), key(21, 97))
        XCTAssertNotEqual(key(20, 100), key(22.5, 100))
    }

    func testDockRenderKeyFollowsTheSelectedProviderMinimum() {
        typealias Slot = TokenRemainHeadLogoArtwork.Slot
        let first = [Slot(provider: .claude, remainingPercent: 45), Slot(provider: .cursor, remainingPercent: 12)]
        let swapped = [Slot(provider: .cursor, remainingPercent: 12), Slot(provider: .claude, remainingPercent: 45)]
        XCTAssertEqual(TokenRemainHeadLogoArtwork.renderKey(slots: first), TokenRemainHeadLogoArtwork.renderKey(slots: swapped))
        XCTAssertEqual(TokenRemainHeadLogoArtwork.renderKey(slots: first), TokenRemainHeadLogoArtwork.renderKey(claudeRemaining: 45, codexRemaining: 12))
        XCTAssertEqual(TokenRemainHeadLogoArtwork.moodRemaining(first), 12)
        XCTAssertEqual(TokenRemainHeadLogoArtwork.moodRemaining([Slot(provider: .grok, remainingPercent: nil), Slot(provider: .cursor, remainingPercent: 12)]), 12)
        XCTAssertNil(TokenRemainHeadLogoArtwork.moodRemaining([]))
        XCTAssertNil(TokenRemainHeadLogoArtwork.moodRemaining([Slot(provider: .cursor, remainingPercent: nil)]))
    }

    func testDotCountMappingAndSizeThresholds() {
        let values: [(Double?, Int)] = [(nil, 0), (0, 0), (2, 1), (2.5, 1), (50, 10), (97, 19), (100, 20), (-1, 0), (200, 20)]
        for (value, count) in values {
            XCTAssertEqual(TokenRemainHeadLogoArtwork.litCount(remainingPercent: value), count, "remaining \(String(describing: value))")
        }
        XCTAssertEqual(TokenRemainHeadLogoArtwork.litCount(remainingPercent: 7.5, variant: .full), 2)
        XCTAssertEqual(TokenRemainHeadLogoArtwork.litCount(remainingPercent: nil, variant: .medium), 0)
        XCTAssertEqual(TokenRemainHeadLogoArtwork.litCount(remainingPercent: 0, variant: .medium), 0)
        XCTAssertEqual(TokenRemainHeadLogoArtwork.litCount(remainingPercent: 2, variant: .medium), 1)
        XCTAssertEqual(TokenRemainHeadLogoArtwork.litCount(remainingPercent: 15, variant: .medium), 2)
        XCTAssertEqual(TokenRemainHeadLogoArtwork.litCount(remainingPercent: 50, variant: .medium), 5)
        XCTAssertEqual(TokenRemainHeadLogoArtwork.litCount(remainingPercent: 100, variant: .medium), 10)
        XCTAssertEqual(DotRingIconArtwork.Variant.resolve(pixelSize: 16), .small)
        XCTAssertEqual(DotRingIconArtwork.Variant.resolve(pixelSize: 31), .small)
        XCTAssertEqual(DotRingIconArtwork.Variant.resolve(pixelSize: 32), .medium)
        XCTAssertEqual(DotRingIconArtwork.Variant.resolve(pixelSize: 63), .medium)
        XCTAssertEqual(DotRingIconArtwork.Variant.resolve(pixelSize: 64), .full)
    }

    func testDockDotsKeepTheSameCyanAtLowQuotaAndForEveryProvider() throws {
        for provider in ProviderQuota.Provider.displayOrder {
            let image = TokenRemainHeadLogoArtwork.image(slots: [.init(provider: provider, remainingPercent: 2)], size: 1024)
            let color = try pixel(image, x: 512, y: 112)
            XCTAssertEqual(color.redComponent, 62.0 / 255, accuracy: 0.002)
            XCTAssertEqual(color.greenComponent, 207.0 / 255, accuracy: 0.002)
            XCTAssertEqual(color.blueComponent, 224.0 / 255, accuracy: 0.002)
        }
    }

    private func pixel(_ image: NSImage, x: Int, y: Int) throws -> NSColor {
        // NSBitmapImageRep(cgImage:).colorAt can reinterpret the buffer using
        // a device profile. Measure the actual NSImage draw in explicit sRGB,
        // as the existing Dock tile contract does, without widening tolerance.
        let width = Int(image.size.width), height = Int(image.size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        // The explicit bitmap buffer uses top-origin rows, confirmed by a
        // one-lit-dot NSImage draw probe (top row 112 is cyan, row 912 dim).
        let index = (y * width + x) * 4
        let alpha = Double(pixels[index + 3]) / 255
        func channel(_ offset: Int) -> Double { alpha == 0 ? 0 : Double(pixels[index + offset]) / 255 / alpha }
        return NSColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: alpha)
    }

    @MainActor
    func testHeadLogoSlotsFollowTheUsersOrderAndHeadlineWindow() {
        let cursor = ProviderQuota(
            provider: .cursor,
            primary: QuotaWindow(usedPercent: 30, windowMinutes: 43_200, resetsAt: nil),
            secondary: nil,
            planName: nil,
            capturedAt: .now
        )
        let slots = StatusBarPresentation.headLogoSlots(
            providers: [.cursor, .claude],
            strategy: .shortestWindow,
            quota: { $0 == .cursor ? cursor : nil }
        )
        XCTAssertEqual(slots, [TokenRemainHeadLogoArtwork.Slot(provider: .cursor, remainingPercent: 70)])
    }

    @MainActor
    func testSingleDockAppDoesNotFallBackToTheLegacySecondSelection() {
        var consulted: [ProviderQuota.Provider] = []
        let slots = StatusBarPresentation.headLogoSlots(
            providers: [.claude, .codex], strategy: .shortestWindow,
            quota: { consulted.append($0); return nil }
        )
        XCTAssertEqual(consulted, [.claude])
        XCTAssertEqual(slots, [.init(provider: .claude, remainingPercent: nil)])
        XCTAssertNil(TokenRemainHeadLogoArtwork.moodRemaining(slots))
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

    func testMenuBarSummaryDefaultsToShortestGeneralWindowAndIgnoresFableQuota() {
        let claude = ProviderQuota(
            provider: .claude,
            primary: QuotaWindow(usedPercent: 11, windowMinutes: 300, resetsAt: nil),
            secondary: QuotaWindow(usedPercent: 28, windowMinutes: 10_080, resetsAt: nil),
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
            89
        )
        XCTAssertEqual(
            StatusBarPresentation.remainingText(for: claude),
            "89%"
        )
        XCTAssertEqual(
            StatusBarPresentation.tooltipProviderLabel(.claude, quota: claude),
            "Claude · \(UsageFormatting.windowName(minutes: 300))"
        )
        XCTAssertEqual(
            StatusBarPresentation.headlineRemainingPercent(
                in: claude,
                strategy: .lowestRemaining
            ),
            72
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

    func testDockRingStartsAtTwelveAndProceedsClockwise() throws {
        let image = TokenRemainHeadLogoArtwork.image(claudeRemaining: 5, codexRemaining: nil, size: 1024)
        let top = try pixel(image, x: 512, y: 112)
        let right = try pixel(image, x: 912, y: 512)
        let left = try pixel(image, x: 112, y: 512)
        XCTAssertEqual(top.greenComponent, 207.0 / 255, accuracy: 0.002)
        XCTAssertEqual(right.redComponent, 43.0 / 255, accuracy: 0.002)
        XCTAssertEqual(left.blueComponent, 84.0 / 255, accuracy: 0.002)
        let zero = TokenRemainHeadLogoArtwork.image(claudeRemaining: 0, codexRemaining: nil, size: 1024)
        XCTAssertEqual(try pixel(zero, x: 512, y: 112).redComponent, 43.0 / 255, accuracy: 0.002)
        XCTAssertEqual(try pixel(zero, x: 439, y: 506).greenComponent, 207.0 / 255, accuracy: 0.002)
    }

    @MainActor
    func testDockLogoDefaultsEachProviderToItsShortestGeneralWindow() {
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

        let tightest = UsageStore.logoQuotaSelection(
            from: [claude, codex],
            strategy: .lowestRemaining
        )
        XCTAssertEqual(tightest?.provider, .claude)
        XCTAssertEqual(tightest?.windowMinutes, 10_080)
        XCTAssertEqual(tightest?.remainingPercent, 15)
    }

    @MainActor
    func testDockLogoUsesShortestWindowEvenWhenItIsSecondary() {
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

    // MARK: - macOS 26 app icon

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The bundled Icon Composer icon and the running Dock tile are drawn by
    /// different code; the same navy in both is what keeps launching the app
    /// from visibly swapping its icon.
    func testIconComposerFillMatchesTheRuntimeDockTile() throws {
        let iconURL = repositoryRoot.appending(path: "Resources/AppIcon.icon")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: iconURL.appending(path: "icon.json"))) as? [String: Any]
        )
        let fill = try XCTUnwrap((json["fill"] as? [String: Any])?["solid"] as? String)
        let components = try XCTUnwrap(fill.split(separator: ":").last)
            .split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(components.count, 4)
        let tile = TokenRemainHeadLogoArtwork.dockTileFill
        XCTAssertEqual(components[0], tile.red, accuracy: 0.002)
        XCTAssertEqual(components[1], tile.green, accuracy: 0.002)
        XCTAssertEqual(components[2], tile.blue, accuracy: 0.002)

        // Every layer must point at an image that ships in the package.
        let groups = try XCTUnwrap(json["groups"] as? [[String: Any]])
        let images = groups.flatMap { ($0["layers"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["image-name"] as? String }
        XCTAssertFalse(images.isEmpty)
        for image in images {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: iconURL.appending(path: "Assets/\(image)").path),
                "missing AppIcon.icon asset \(image)"
            )
        }
    }

    /// macOS 26+ picks the compiled icon by name; older systems keep the
    /// full-resolution icns, which actool's own fallback icns would downgrade.
    func testInfoPlistNamesTheIconComposerIconAndKeepsTheIcnsFallback() throws {
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: repositoryRoot.appending(path: "Resources/Info.plist")) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "TokenRemain.icns")
    }

    func testIcnsSmallEntryKeepsHeadOnlyARGBAndCorrectTransparentEdges() throws {
        let data = try Data(contentsOf: repositoryRoot.appending(path: "Sources/UsageDock/Resources/TokenRemain.icns"))
        func length(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        var offset = 8
        var argb: Data?
        while offset + 8 <= data.count {
            let count = length(at: offset + 4)
            XCTAssertGreaterThanOrEqual(count, 8)
            guard count >= 8, offset + count <= data.count else { break }
            if String(data: data[offset..<(offset + 4)], encoding: .ascii) == "ic04" {
                argb = data.subdata(in: (offset + 8)..<(offset + count)); break
            }
            offset += count
        }
        let payload = try XCTUnwrap(argb)
        XCTAssertEqual(String(data: payload.prefix(4), encoding: .ascii), "ARGB")
        // iconutil's reverse PNG export is lossy for small ARGB entries.
        // Inspect the four stored straight-alpha RLE planes directly instead.
        var cursor = 4
        var planes: [[UInt8]] = []
        for _ in 0..<4 {
            var plane: [UInt8] = []
            while plane.count < 256 {
                let control = Int(payload[cursor]); cursor += 1
                if control < 128 {
                    plane.append(contentsOf: payload[cursor..<(cursor + control + 1)])
                    cursor += control + 1
                } else {
                    plane.append(contentsOf: repeatElement(payload[cursor], count: control - 125))
                    cursor += 1
                }
            }
            XCTAssertEqual(plane.count, 256)
            planes.append(plane)
        }
        XCTAssertEqual(planes[0][0], 0)
        XCTAssertEqual(planes[3][2 * 16 + 8], 49)
        XCTAssertGreaterThan(planes[2][8 * 16 + 6], 150)
        XCTAssertGreaterThan(planes[2][8 * 16 + 9], 150)
        XCTAssertLessThan(planes[2][8 * 16 + 8], 100)
    }

    func testDockTileDrawsTheIconShapeWhileTheBareLogoStaysTransparent() throws {
        let tile = TokenRemainHeadLogoArtwork.image(slots: [], size: 256, style: .dockTile)
        XCTAssertEqual(try pixel(tile, x: 4, y: 128).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try pixel(tile, x: 30, y: 30).alphaComponent, 0, accuracy: 0.01)
        let inside = try pixel(tile, x: 128, y: 40)
        XCTAssertEqual(inside.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(inside.redComponent, TokenRemainHeadLogoArtwork.dockTileFill.red, accuracy: 0.002)
        XCTAssertEqual(inside.blueComponent, TokenRemainHeadLogoArtwork.dockTileFill.blue, accuracy: 0.002)
        let bare = TokenRemainHeadLogoArtwork.image(slots: [], size: 256, style: .bare)
        XCTAssertEqual(try pixel(bare, x: 128, y: 40).alphaComponent, 0, accuracy: 0.01)
    }
}
