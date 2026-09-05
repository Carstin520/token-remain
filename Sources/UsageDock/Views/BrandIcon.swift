import AppKit
import SwiftUI

/// Renders each provider's authentic brand mark from one centralized mapping.
///
/// Claude and Codex retain their existing artwork. Every other provider uses a
/// bundled vendor artwork: full-color marks keep their original colors, while
/// single-color marks use the provider accent supplied by the surrounding UI.
struct BrandIcon: View {
    struct Artwork: Equatable {
        let resourceName: String
        let isTemplate: Bool
        /// Extra inner padding applied only when rasterizing the menu-bar
        /// attachment. Zero keeps the vendor canvas. Grok's Lobe mark is a
        /// diagonal that touches the PNG edges, so it needs room or the 13pt
        /// status-item glyph sits off the percent baseline.
        var menuBarPaddingRatio: CGFloat = 0
    }

    let provider: ProviderQuota.Provider
    var color: Color?

    private var tint: Color {
        color ?? DashboardTheme.accent(for: provider)
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
        default:
            if let artwork = Self.artwork(for: provider) {
                Image(nsImage: Self.providerImage(artwork, provider: provider))
                    .resizable()
                    .renderingMode(artwork.isTemplate ? .template : .original)
                    .scaledToFit()
                    .foregroundStyle(tint)
                    .accessibilityLabel(provider.rawValue)
            } else {
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint)
                    .accessibilityLabel(provider.rawValue)
            }
        }
    }

    /// Returns provider artwork for menu-bar attachments. Template SVGs follow
    /// the current appearance; full-color assets retain their vendor palette.
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
        default:
            guard let artwork = artwork(for: provider) else {
                return fallbackImage(for: provider, size: size)
            }
            image = providerImage(artwork, provider: provider).copy() as? NSImage
                ?? fallbackImage(for: provider, size: size)
            image.isTemplate = artwork.isTemplate
        }

        image.size = NSSize(width: size, height: size)
        return image
    }

    /// Rasterizes a status-item glyph whose point size matches the attachment
    /// bounds. `image(for:size:)` only changes `NSImage.size` on a 640px Lobe
    /// PNG; `NSTextAttachmentCell` can still key off the pixel buffer and
    /// draw edge-flush marks (Grok) off the 12pt percent baseline.
    static func menuBarImage(
        for provider: ProviderQuota.Provider,
        size: CGFloat
    ) -> NSImage {
        let source = image(for: provider, size: size)
        let paddingRatio = artwork(for: provider)?.menuBarPaddingRatio ?? 0
        return rasterizeForMenuBar(source, pointSize: size, paddingRatio: paddingRatio)
    }

    static func artwork(for provider: ProviderQuota.Provider) -> Artwork? {
        switch provider {
        case .claude, .codex:
            return nil
        case .cursor:
            return Artwork(resourceName: "cursor", isTemplate: true)
        case .grok:
            return Artwork(
                resourceName: "grok",
                isTemplate: true,
                menuBarPaddingRatio: 0.14
            )
        case .zai, .zaiTeam:
            return Artwork(resourceName: "zai", isTemplate: true)
        case .copilot:
            return Artwork(resourceName: "github-copilot", isTemplate: true)
        case .devin:
            return Artwork(resourceName: "devin", isTemplate: false)
        case .windsurf:
            return Artwork(resourceName: "windsurf", isTemplate: false)
        case .openrouter:
            return Artwork(resourceName: "openrouter", isTemplate: false)
        case .antigravity:
            return Artwork(resourceName: "antigravity", isTemplate: false)
        case .opencode:
            return Artwork(resourceName: "opencode", isTemplate: true)
        case .deepseek:
            return Artwork(resourceName: "deepseek", isTemplate: false)
        case .kimi:
            return Artwork(resourceName: "kimi", isTemplate: false)
        case .minimax:
            return Artwork(resourceName: "minimax", isTemplate: false)
        case .mimo:
            return Artwork(resourceName: "mimo", isTemplate: true)
        case .qoder:
            return Artwork(resourceName: "qoder", isTemplate: false)
        case .kiro:
            return Artwork(resourceName: "kiro", isTemplate: false)
        case .volcengine:
            return Artwork(resourceName: "volcengine", isTemplate: false)
        case .ollama:
            return Artwork(resourceName: "ollama", isTemplate: true)
        case .thirdParty:
            return nil
        }
    }

    static func resourceURL(for artwork: Artwork) -> URL? {
        if let bundled = AppResourceBundle.bundle.url(
            forResource: artwork.resourceName,
            withExtension: "png",
            subdirectory: "ProviderIcons"
        ) {
            return bundled
        }

        #if DEBUG
        // SwiftPM deliberately excludes app resources. Tests and direct debug
        // binaries therefore resolve the checked-in asset beside this source.
        let sourceResource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ProviderIcons")
            .appendingPathComponent(artwork.resourceName)
            .appendingPathExtension("png")
        if FileManager.default.fileExists(atPath: sourceResource.path) {
            return sourceResource
        }
        #endif

        return nil
    }

    private static func providerImage(
        _ artwork: Artwork,
        provider: ProviderQuota.Provider
    ) -> NSImage {
        guard let url = resourceURL(for: artwork),
              let image = NSImage(contentsOf: url) else {
            return fallbackImage(for: provider, size: 32)
        }
        image.isTemplate = artwork.isTemplate
        image.accessibilityDescription = provider.rawValue
        return image
    }

    private static func claudeImage() -> NSImage {
        AppResourceBundle.bundle.url(forResource: "claude", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(
                systemSymbolName: "questionmark.circle",
                accessibilityDescription: ProviderQuota.Provider.claude.rawValue
            )
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }

    /// Draws `source` into a 2× bitmap of `pointSize`. When `paddingRatio` is
    /// positive, the mark is scaled into a centered inner square so spikes
    /// that touch the vendor canvas no longer flush against neighboring text.
    static func rasterizeForMenuBar(
        _ source: NSImage,
        pointSize: CGFloat,
        paddingRatio: CGFloat
    ) -> NSImage {
        let scale: CGFloat = 2
        let pixels = max(1, Int((pointSize * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return source
        }
        rep.size = NSSize(width: pointSize, height: pointSize)

        // The bitmap context is sized in points (`rep.size`), not pixels.
        let clampedPad = min(max(paddingRatio, 0), 0.4)
        let pad = clampedPad * pointSize
        let inner = max(1, pointSize - 2 * pad)
        let dest = NSRect(x: pad, y: pad, width: inner, height: inner)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: dest,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = source.isTemplate
        return image
    }

    private static func fallbackImage(
        for provider: ProviderQuota.Provider,
        size: CGFloat
    ) -> NSImage {
        let image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: provider.rawValue
        ) ?? NSImage(size: NSSize(width: size, height: size))
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

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
