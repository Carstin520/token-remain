import AppKit
import SwiftUI

/// Up to three vendor logos standing in for a multi-vendor pool's name,
/// largest usage first. Hovering a logo names the models behind it.
struct ModelVendorMarkStrip: View {
    let marks: [ModelVendorMark]
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 4) {
            ForEach(marks.prefix(ModelVendorMark.limit)) { mark in
                ModelVendorIcon(vendor: mark.vendor)
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
                    .help(mark.helpText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(marks.prefix(ModelVendorMark.limit).map(\.vendor.displayName).joined(separator: ", "))
    }
}

/// A model vendor's mark. Vendors that also ship a coding tool reuse that
/// provider's bundled artwork; OpenAI uses its bundled template mark, Google
/// a drawn Gemini spark, and unrecognized vendors a neutral chip glyph.
struct ModelVendorIcon: View {
    let vendor: ModelVendor

    @ViewBuilder
    var body: some View {
        switch vendor {
        case .anthropic: BrandIcon(provider: .claude)
        case .openai:
            Image(nsImage: Self.openAIImage())
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .usageDockAdaptiveForeground(.primary)
        case .google: GeminiSparkGlyph()
        case .xai: BrandIcon(provider: .grok)
        case .deepseek: BrandIcon(provider: .deepseek)
        case .moonshot: BrandIcon(provider: .kimi)
        case .zhipu: BrandIcon(provider: .zai)
        case .minimax: BrandIcon(provider: .minimax)
        case .alibaba: BrandIcon(provider: .alibabaTokenPlan)
        case .xiaomi: BrandIcon(provider: .mimo)
        case .bytedance: BrandIcon(provider: .volcengine)
        case .other:
            Image(systemName: "cpu")
                .resizable()
                .scaledToFit()
                .usageDockAdaptiveForeground(.secondary)
        }
    }

    static func openAIResourceURL() -> URL? {
        if let bundled = AppResourceBundle.bundle.url(forResource: "openai", withExtension: "png") {
            return bundled
        }
        #if DEBUG
        // SwiftPM excludes app resources; tests and debug binaries read the
        // checked-in asset, as `BrandIcon.claudeResourceURL` does.
        let sourceResource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/openai.png")
        if FileManager.default.fileExists(atPath: sourceResource.path) {
            return sourceResource
        }
        #endif
        return nil
    }

    private static func openAIImage() -> NSImage {
        let image = openAIResourceURL().flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: ModelVendor.openai.displayName)
            ?? NSImage(size: NSSize(width: 32, height: 32))
        image.isTemplate = true
        return image
    }
}

/// Gemini's four-point spark: concave edges meeting at the center, in the
/// blue-to-rose gradient of the Gemini mark. Drawn rather than bundled, so it
/// stays crisp at row-title size.
private struct GeminiSparkGlyph: View {
    var body: some View {
        Canvas { context, size in
            let inset = min(size.width, size.height) * 0.04
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            // Pulling each control point slightly toward its corner keeps the
            // waist wide enough to read at 13 pt.
            func control(_ cornerX: CGFloat, _ cornerY: CGFloat) -> CGPoint {
                CGPoint(
                    x: rect.midX + (cornerX - rect.midX) * 0.16,
                    y: rect.midY + (cornerY - rect.midY) * 0.16
                )
            }
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: control(rect.maxX, rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: control(rect.maxX, rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: control(rect.minX, rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: control(rect.minX, rect.minY))
            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(hex: 0x4796E3),
                        Color(hex: 0x9177C7),
                        Color(hex: 0xCA6673)
                    ]),
                    startPoint: CGPoint(x: rect.minX, y: rect.maxY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.minY)
                )
            )
        }
    }
}
