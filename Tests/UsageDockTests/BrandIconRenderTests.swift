import AppKit
import Testing
@testable import UsageDock

@Suite("Brand icon rendering")
struct BrandIconRenderTests {
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
            #expect(coverage < 0.95, "\(provider.displayName) icon is a solid block (coverage \(coverage))")

            if let outputDirectory,
               let png = bitmap.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: outputDirectory)
                    .appendingPathComponent("brand-\(provider.displayName.lowercased()).png")
                try? png.write(to: url)
            }
        }
    }
}
