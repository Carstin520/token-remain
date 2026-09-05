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

    @Test("Grok menu-bar glyph is inset so the diagonal mark does not flush the canvas")
    @MainActor
    func grokMenuBarImageIsPadded() throws {
        let raw = BrandIcon.image(for: .grok, size: 64)
        let menu = BrandIcon.menuBarImage(for: .grok, size: 64)

        let rawPad = try #require(minPaddingRatio(of: raw))
        let menuPad = try #require(minPaddingRatio(of: menu))
        #expect(rawPad < 0.03, "Grok's Lobe PNG should still touch the canvas (got \(rawPad))")
        #expect(menuPad > 0.10, "menu-bar Grok glyph should keep inner padding (got \(menuPad))")
        #expect(menu.size == NSSize(width: 64, height: 64))
        #expect(menu.isTemplate)

        let bitmap = try #require(NSBitmapImageRep(data: try #require(menu.tiffRepresentation)))
        #expect(bitmap.pixelsWide == 128)
        #expect(bitmap.pixelsHigh == 128)
    }

    @Test("Menu-bar rasterization keeps Claude and Codex filling their canvas")
    @MainActor
    func menuBarRasterizationDoesNotShrinkAlreadyPaddedMarks() throws {
        for provider in [ProviderQuota.Provider.claude, .codex] {
            let raw = BrandIcon.image(for: provider, size: 64)
            let menu = BrandIcon.menuBarImage(for: provider, size: 64)
            let rawPad = try #require(minPaddingRatio(of: raw))
            let menuPad = try #require(minPaddingRatio(of: menu))
            #expect(
                abs(menuPad - rawPad) < 0.06,
                "\(provider.displayName) padding drifted from \(rawPad) to \(menuPad)"
            )
        }
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
