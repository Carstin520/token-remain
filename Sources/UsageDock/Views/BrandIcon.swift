import AppKit
import SwiftUI

/// Provider identity marks with separate screen and menu-bar renderers.
///
/// Claude keeps its bundled vendor artwork. Codex is drawn as native vector
/// geometry so its blue-violet flower and white prompt stay smooth at every
/// SwiftUI size. The menu-bar variant is also drawn in color so the small icon
/// retains both the blue-violet identity and the white `>_` prompt.
struct BrandIcon: View {
    let provider: ProviderQuota.Provider
    var color: Color?

    private var tint: Color {
        color ?? DashboardTheme.claudeBrand
    }

    @ViewBuilder
    var body: some View {
        switch provider {
        case .claude:
            Image(nsImage: Self.claudeImage())
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(tint)
                .accessibilityLabel(provider.rawValue)
        case .codex:
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(
                    CodexBrandGlyph.flower(in: rect),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hex: 0xC49AF8),
                            Color(hex: 0x6A78FF),
                            Color(hex: 0x245BFF)
                        ]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
                context.stroke(
                    CodexBrandGlyph.prompt(in: rect),
                    with: .color(.white),
                    style: StrokeStyle(
                        lineWidth: min(size.width, size.height) * CodexBrandGlyph.promptStrokeRatio,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
            .accessibilityLabel(provider.rawValue)
        }
    }

    /// Returns provider artwork for menu-bar attachments. Claude remains a
    /// system-tinted template; Codex deliberately keeps its native color.
    static func image(
        for provider: ProviderQuota.Provider,
        size: CGFloat = 32
    ) -> NSImage {
        let image: NSImage
        switch provider {
        case .claude:
            image = claudeImage().copy() as? NSImage
                ?? NSImage(size: NSSize(width: size, height: size))
            image.isTemplate = true
        case .codex:
            image = CodexBrandGlyph.colorImage(size: size)
            image.isTemplate = false
        }

        image.size = NSSize(width: size, height: size)
        return image
    }

    private static func claudeImage() -> NSImage {
        Bundle.main.url(forResource: "claude", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(
                systemSymbolName: "questionmark.circle",
                accessibilityDescription: ProviderQuota.Provider.claude.rawValue
            )
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }
}

/// Geometry shared by the SwiftUI color glyph and AppKit template glyph.
enum CodexBrandGlyph {
    static let promptStrokeRatio: CGFloat = 0.115

    static func flower(in rect: CGRect) -> Path {
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX + x * rect.width,
                y: rect.minY + y * rect.height,
                width: width * rect.width,
                height: height * rect.height
            )
        }

        var path = Path()
        // A filled center joins six overlapping rounded lobes into one smooth
        // flower/cloud silhouette without raster cutout edges.
        path.addEllipse(in: ellipse(0.20, 0.20, 0.60, 0.60))
        path.addEllipse(in: ellipse(0.30, 0.04, 0.40, 0.40))
        path.addEllipse(in: ellipse(0.56, 0.16, 0.38, 0.40))
        path.addEllipse(in: ellipse(0.58, 0.45, 0.38, 0.40))
        path.addEllipse(in: ellipse(0.34, 0.58, 0.40, 0.38))
        path.addEllipse(in: ellipse(0.08, 0.44, 0.40, 0.42))
        path.addEllipse(in: ellipse(0.06, 0.16, 0.42, 0.42))
        return path
    }

    static func prompt(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + x * rect.width,
                y: rect.minY + y * rect.height
            )
        }

        var path = Path()
        path.move(to: point(0.30, 0.34))
        path.addLine(to: point(0.45, 0.50))
        path.addLine(to: point(0.30, 0.66))
        path.move(to: point(0.55, 0.66))
        path.addLine(to: point(0.73, 0.66))
        return path
    }

    static func colorImage(size: CGFloat) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        let image = NSImage(size: dimensions, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            context.saveGState()
            context.addPath(flower(in: rect).cgPath)
            context.clip()

            let colors = [
                NSColor(srgbRed: 0xC4 / 255, green: 0x9A / 255, blue: 0xF8 / 255, alpha: 1).cgColor,
                NSColor(srgbRed: 0x6A / 255, green: 0x78 / 255, blue: 0xFF / 255, alpha: 1).cgColor,
                NSColor(srgbRed: 0x24 / 255, green: 0x5B / 255, blue: 0xFF / 255, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.55, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.midX, y: rect.minY),
                    end: CGPoint(x: rect.midX, y: rect.maxY),
                    options: []
                )
            }
            context.restoreGState()

            context.addPath(prompt(in: rect).cgPath)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(min(rect.width, rect.height) * promptStrokeRatio)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            return true
        }
        image.isTemplate = false
        return image
    }
}
