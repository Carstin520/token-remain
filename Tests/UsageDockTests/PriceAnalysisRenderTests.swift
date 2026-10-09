import AppKit
import SwiftUI
import Testing
@testable import UsageDock

@Suite("Price analysis native layout")
@MainActor
struct PriceAnalysisRenderTests {
    @Test(arguments: [480.0, 760.0]) func rendersCommonAndLegacyModels(width: Double) throws {
        let day = ModelPriceAnalysisTests.day()
        let view = PriceAnalysisPanel(days: [day, ModelPriceAnalysisTests.day(read: nil, write: nil)],
                                      agentIDs: ["claude"],
                                      snapshot: .init(prices: ["claude-fixture": ModelPriceAnalysisTests.price], fetchedAt: .now))
            .padding(20).frame(width: width).background(DashboardTheme.canvas).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rendered = try #require(renderer.nsImage)
        #expect(Int(rendered.size.width.rounded()) == Int(width))
        #expect(rendered.size.height > 250)
        if let directory = ProcessInfo.processInfo.environment["TOKENREMAIN_UI_EVIDENCE"] {
            let tiff = try #require(rendered.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("prices-\(Int(width)).png"))
        }
    }
}
