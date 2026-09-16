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

    @Test("Grok menu-bar glyph is inset so the diagonal mark does not flush the canvas", arguments: [13.0, 64.0])
    @MainActor
    func grokMenuBarImageIsPadded(size: Double) throws {
        let raw = BrandIcon.image(for: .grok, size: size)
        let menu = BrandIcon.menuBarImage(for: .grok, size: size)

        let rawPad = try #require(minPaddingRatio(of: raw))
        let menuPad = try #require(minPaddingRatio(of: menu))
        #expect(rawPad < 0.03, "Grok's Lobe PNG should still touch the canvas (got \(rawPad))")
        #expect(menuPad > 0.10, "menu-bar Grok glyph should keep inner padding (got \(menuPad))")
        #expect(menu.size == NSSize(width: size, height: size))
        #expect(menu.isTemplate)

        let tiff = try #require(menu.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        #expect(bitmap.pixelsWide == Int(size * 2))
        #expect(bitmap.pixelsHigh == Int(size * 2))
    }

    @Test("Menu-bar rasterization keeps Claude and Codex filling their canvas", arguments: [13.0, 64.0])
    @MainActor
    func menuBarRasterizationDoesNotShrinkAlreadyPaddedMarks(size: Double) throws {
        for provider in [ProviderQuota.Provider.claude, .codex] {
            let raw = BrandIcon.image(for: provider, size: size)
            let menu = BrandIcon.menuBarImage(for: provider, size: size)
            let rawPad = try #require(minPaddingRatio(of: raw))
            let menuPad = try #require(minPaddingRatio(of: menu))
            #expect(
                abs(menuPad - rawPad) < 0.06,
                "\(provider.displayName) padding drifted from \(rawPad) to \(menuPad)"
            )
        }
    }

    @Test("Actual status attachments stay visible through light/dark/light transitions", arguments: [1, 2])
    @MainActor
    func statusAttachmentsFollowAppearance(scale: Int) throws {
        for provider in ProviderQuota.Provider.displayOrder {
            guard BrandIcon.image(for: provider, size: 13).isTemplate else { continue }
            // Reuse the same attachment, as the status title does when only the
            // appearance changes and the quota fingerprint stays unchanged.
            let attachment = StatusBarController.statusIcon(provider, size: 13)
            var contrasts: [CGFloat] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                let bitmap = try renderAttachment(attachment, appearance: appearance, scale: scale)
                // Integrate contrast so antialiased thin strokes count at 1x;
                // a hard per-pixel cutoff incorrectly discards visible strokes.
                var contrast: CGFloat = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        contrast += appearance == .darkAqua ? luminance : 1 - luminance
                    }
                }
                contrasts.append(contrast)
                #expect(
                    contrast > CGFloat(5 * scale * scale),
                    "\(provider.displayName) attachment is invisible in \(appearance.rawValue) at \(scale)x"
                )
            }
            #expect(contrasts[1] > contrasts[0] * 0.75, "Dark appearance must retain the visible mark")
            #expect(abs(contrasts[2] - contrasts[0]) < 0.01, "Returning to light must restore the same mark")
        }
    }

    @Test("Color status attachments retain their colors in both appearances", arguments: [1, 2])
    @MainActor
    func colorStatusAttachmentsKeepTheirPalette(scale: Int) throws {
        let attachment = StatusBarController.statusIcon(.codex, size: 13)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try renderAttachment(attachment, appearance: appearance, scale: scale)
            var coloredPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let components = [color.redComponent, color.greenComponent, color.blueComponent]
                    if components.max()! - components.min()! > 0.2 {
                        coloredPixels += 1
                    }
                }
            }
            #expect(coloredPixels > 5 * scale * scale)
        }
    }

    @MainActor
    private func renderAttachment(
        _ attachment: NSAttributedString,
        appearance: NSAppearance.Name,
        scale: Int
    ) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40 * scale,
            pixelsHigh: 32 * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 40, height: 32)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let resolvedAppearance = try #require(NSAppearance(named: appearance))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        resolvedAppearance.performAsCurrentDrawingAppearance {
            (appearance == .darkAqua ? NSColor.black : .white).setFill()
            NSRect(x: 0, y: 0, width: 40, height: 32).fill()
            // No percentage text: text contrast must not mask an invisible icon.
            attachment.draw(at: NSPoint(x: 8, y: 8))
        }
        return bitmap
    }

    private func minPaddingRatio(of image: NSImage) -> CGFloat? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.08 else {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let pad = min(minX, minY, width - 1 - maxX, height - 1 - maxY)
        return CGFloat(pad) / CGFloat(max(width, height))
    }
}
