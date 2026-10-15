import AppKit
import Testing
@testable import UsageDock

@Suite("Brand icon rendering")
struct BrandIconRenderTests {
    @Test("Branded providers have explicit artwork; shared products reuse only their real brand")
    func authenticArtworkCoverage() throws {
        let resourceProviders = ProviderQuota.Provider.displayOrder.filter {
            $0 != .claude && $0 != .codex && $0 != .thirdParty
        }
        var resourceNames = Set<String>()

        for provider in resourceProviders {
            let artwork = try #require(
                BrandIcon.artwork(for: provider),
                "\(provider.displayName) is missing an explicit brand artwork mapping"
            )
            let inserted = resourceNames.insert(artwork.resourceName).inserted
            if provider == .zaiTeam {
                #expect(!inserted && artwork.resourceName == "zai")
            } else {
                #expect(inserted, "\(provider.displayName) reuses another provider's brand resource")
            }

            let resourceURL = try #require(
                BrandIcon.resourceURL(for: artwork),
                "\(provider.displayName) artwork is not available to the renderer"
            )
            #expect(resourceURL.pathExtension == "png")
            #expect(FileManager.default.fileExists(atPath: resourceURL.path))
        }

        #expect(resourceNames.count == resourceProviders.count - 1)
        #expect(BrandIcon.artwork(for: .thirdParty) == nil)
    }

    @Test("Claude rendering loads the real brand asset instead of a fallback symbol")
    @MainActor
    func claudeArtworkIsAvailable() throws {
        let resource = try #require(BrandIcon.claudeResourceURL())
        #expect(resource.lastPathComponent == "claude.png")
        let source = try #require(NSImage(contentsOf: resource))
        source.size = NSSize(width: 64, height: 64)
        let rendered = BrandIcon.image(for: .claude, size: 64)
        let expected = try #require(source.tiffRepresentation)
        let actual = try #require(rendered.tiffRepresentation)
        #expect(actual == expected)
    }

    @Test("Menu-bar brand images render with visible content for every provider")
    @MainActor
    func rendersAllProviders() throws {
        let outputDirectory = ProcessInfo.processInfo.environment["USAGEDOCK_ICON_DUMP_DIR"]
        for provider in ProviderQuota.Provider.displayOrder {
            let image = BrandIcon.image(for: provider, size: 128)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))

            // 图标必须画出实际内容:统计非透明像素占比,空白即失败。
            var opaque = 0
            let sampleStep = 4
            for x in stride(from: 0, to: bitmap.pixelsWide, by: sampleStep) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: sampleStep) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 {
                        opaque += 1
                    }
                }
            }
            let samples = (bitmap.pixelsWide / sampleStep) * (bitmap.pixelsHigh / sampleStep)
            let coverage = Double(opaque) / Double(max(1, samples))
            #expect(coverage > 0.05, "\(provider.displayName) icon looks empty (coverage \(coverage))")
            // Official app-tile marks such as Kiro intentionally fill almost
            // the entire square, so reject only a truly opaque fallback block.
            #expect(coverage < 0.99, "\(provider.displayName) icon is a solid block (coverage \(coverage))")

            if let outputDirectory,
               let png = bitmap.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: outputDirectory)
                    .appendingPathComponent("brand-\(provider.displayName.lowercased()).png")
                try? png.write(to: url)
            }
        }
    }

    @Test("All status glyphs use one blue, equal visible size and centered slots", arguments: [13.0, 64.0])
    @MainActor
    func uniformMenuBarGlyphs(size: Double) throws {
        let expected = try #require(BrandIcon.menuBarBlue.usingColorSpace(.deviceRGB))
        for provider in ProviderQuota.Provider.displayOrder {
            let menu = BrandIcon.menuBarImage(for: provider, size: size)
            // Inspect the shipped sRGB bitmap directly. AppKit's TIFF export
            // can tone-map it into an HDR calibrated space on newer displays.
            let bitmap = try #require(menu.representations.first as? NSBitmapImageRep)
            #expect(menu.size == NSSize(width: size, height: size))
            #expect(!menu.isTemplate, "AppKit must not recolor the blue glyph")
            #expect(bitmap.pixelsWide == Int(size * 2))
            #expect(bitmap.pixelsHigh == Int(size * 2))
            var bounds = NSRect.null
            var visible = 0
            var maxColorError: CGFloat = 0
            var pixel = [UInt](repeating: 0, count: bitmap.samplesPerPixel)
            let alphaIndex = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
            let redIndex = alphaIndex == 0 ? 1 : 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    // Compare encoded sRGB channels rather than NSColor's
                    // display/HDR adaptation; alpha still governs visible bounds.
                    bitmap.getPixel(&pixel, atX: x, y: y)
                    guard pixel[alphaIndex] > 38 else { continue }
                    let divisor = bitmap.bitmapFormat.contains(.alphaNonpremultiplied)
                        ? CGFloat(255) : CGFloat(pixel[alphaIndex])
                    visible += 1
                    bounds = bounds.union(NSRect(x: x, y: y, width: 1, height: 1))
                    maxColorError = max(maxColorError, abs(CGFloat(pixel[redIndex]) / divisor - expected.redComponent),
                                        abs(CGFloat(pixel[redIndex + 1]) / divisor - expected.greenComponent),
                                        abs(CGFloat(pixel[redIndex + 2]) / divisor - expected.blueComponent))
                }
            }
            #expect(maxColorError < 0.03, "\(provider) color error: \(maxColorError)")
            #expect(visible > 5, "\(provider) must remain visible")
            #expect(abs(max(bounds.width, bounds.height) - size * 2) <= 1, "\(provider) visible size: \(bounds)")
            #expect(abs(bounds.midX - size) <= 1, "\(provider) horizontal centering")
            #expect(abs(bounds.midY - size) <= 1, "\(provider) vertical centering")
        }
    }

    @Test("Export the native status title for visual review when requested")
    @MainActor
    func statusTitlePreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["USAGEDOCK_STATUS_PREVIEW_DIR"] else { return }
        let title = StatusBarController.statusTitle(
            segments: [(.codex, "94%"), (.zai, "¥12.34"), (.deepseek, "¥56.78")], displayMode: .full
        )
        let bitmap = try renderAttachment(title, appearance: .darkAqua, scale: 2, width: Int(ceil(title.size().width)) + 16)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("状态栏预览.png"))
    }

    @Test("Status numerals use Apple SF Pro with tabular digits")
    @MainActor
    func nativeNumericFont() throws {
        let font = StatusBarController.statusFont
        #expect(font == NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        #expect(font.fontName != NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName)
        #expect(NSAttributedString(string: "111", attributes: [.font: font]).size().width
            == NSAttributedString(string: "888", attributes: [.font: font]).size().width)
        let title = StatusBarController.statusTitle(segments: [(.zai, "¥12.34")], displayMode: .full)
        #expect(title.attribute(.font, at: 2, effectiveRange: nil) as? NSFont == font)
    }

    @Test("Rendered status icons share the digits' vertical center in light and dark appearances", arguments: [1, 2])
    @MainActor
    func statusTitleAlignment(scale: Int) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for provider in ProviderQuota.Provider.displayOrder {
                let title = StatusBarController.statusTitle(segments: [(provider, "888")], displayMode: .full)
                let bitmap = try renderAttachment(title, appearance: appearance, scale: scale)
                var iconBounds = NSRect.null
                var digitBounds = NSRect.null
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        let pixel = NSRect(x: x, y: y, width: 1, height: 1)
                        if color.blueComponent > color.redComponent + 0.2,
                           color.blueComponent > color.greenComponent + 0.2 {
                            iconBounds = iconBounds.union(pixel)
                        } else if x > 22 * scale {
                            let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                            if appearance == .darkAqua ? luminance > 0.6 : luminance < 0.4 {
                                digitBounds = digitBounds.union(pixel)
                            }
                        }
                    }
                }
                #expect(!iconBounds.isNull && !digitBounds.isNull, "\(provider) must draw icon and digits")
                #expect(abs(iconBounds.midY - digitBounds.midY) <= CGFloat(scale), "\(provider) center drift: \(iconBounds.midY) vs \(digitBounds.midY) at \(scale)x")
            }
        }
    }

    @Test("Blue attachments retain their hue through light/dark/light changes", arguments: [1, 2])
    @MainActor
    func blueAttachmentsFollowAppearance(scale: Int) throws {
        for provider in ProviderQuota.Provider.displayOrder {
            let attachment = StatusBarController.statusIcon(provider, size: 13)
            var counts: [Int] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                let bitmap = try renderAttachment(attachment, appearance: appearance, scale: scale)
                var bluePixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if color.blueComponent > color.redComponent + 0.2,
                           color.blueComponent > color.greenComponent + 0.2 { bluePixels += 1 }
                    }
                }
                #expect(bluePixels > 5 * scale * scale, "\(provider) must remain blue and visible")
                counts.append(bluePixels)
            }
            #expect(abs(counts[0] - counts[1]) <= 5 * scale * scale)
            #expect(counts[0] == counts[2])
        }
    }

    @MainActor
    private func renderAttachment(
        _ attachment: NSAttributedString,
        appearance: NSAppearance.Name,
        scale: Int,
        width: Int = 100
    ) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width * scale,
            pixelsHigh: 32 * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: width, height: 32)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let resolvedAppearance = try #require(NSAppearance(named: appearance))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        resolvedAppearance.performAsCurrentDrawingAppearance {
            (appearance == .darkAqua ? NSColor.black : .white).setFill()
            NSRect(x: 0, y: 0, width: width, height: 32).fill()
            // No percentage text: text contrast must not mask an invisible icon.
            attachment.draw(at: NSPoint(x: 8, y: 8))
        }
        return bitmap
    }

}
