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
}
