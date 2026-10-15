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
        case .thirdParty:
            Image(nsImage: GenericRobotGlyph.image(size: 64))
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(tint)
                .accessibilityLabel(provider.displayName)
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
        case .thirdParty:
            image = GenericRobotGlyph.image(size: size)
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

    static let menuBarBlue = NSColor(srgbRed: 0x4D / 255, green: 0x6B / 255, blue: 0xFE / 255, alpha: 1)

    @MainActor private static var menuBarImages: [String: NSImage] = [:]

    /// Status items use one blue and one visible bounding size, independent of
    /// vendor canvas padding. Other app surfaces retain the original artwork.
    @MainActor
    static func menuBarImage(
        for provider: ProviderQuota.Provider,
        size: CGFloat
    ) -> NSImage {
        let key = "\(provider.rawValue):\(size)"
        if let cached = menuBarImages[key] { return cached }
        let source = provider == .codex
            ? CodexBrandGlyph.monochromeImage(size: 64)
            : image(for: provider, size: 64)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var proposed = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let original = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let mask = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                                   bytesPerRow: 128 * 4, space: colorSpace, bitmapInfo: format),
              let data = mask.data?.assumingMemoryBound(to: UInt8.self) else { return source }
        mask.draw(original, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        func colorize(_ bytes: UnsafeMutablePointer<UInt8>, at offset: Int) {
            let alpha = Int(bytes[offset + 3])
            bytes[offset] = UInt8((0x4D * alpha + 127) / 255)
            bytes[offset + 1] = UInt8((0x6B * alpha + 127) / 255)
            bytes[offset + 2] = UInt8((0xFE * alpha + 127) / 255)
        }
        let hasNonWhiteInk = (0..<(128 * 128)).contains { pixel in
            let offset = pixel * 4
            let alpha = Int(data[offset + 3])
            return alpha > 128 && (0..<3).contains { Int(data[offset + $0]) < Int(Double(alpha) * 0.9) }
        }
        var minX = 128, minY = 128, maxX = -1, maxY = -1
        for y in 0..<128 {
            for x in 0..<128 {
                let offset = y * mask.bytesPerRow + x * 4
                let alpha = Int(data[offset + 3])
                guard alpha > 0 else { continue }
                let components = (0..<3).map { Int(data[offset + $0]) }
                // White tile details become transparent cutouts. Work on a
                // known RGBA buffer so all source color spaces behave alike.
                if !source.isTemplate, hasNonWhiteInk, Double(components.min()!) > Double(alpha) * 0.92,
                   Double(components.max()! - components.min()!) < Double(alpha) * 0.08 {
                    data[offset + 3] = 0
                    continue
                }
                colorize(data, at: offset)
                guard alpha > 38 else { continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = mask.makeImage()?.cropping(to: CGRect(
                x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
              )) else { return source }
        let pixels = max(1, Int((size * 2).rounded()))
        guard let output = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                     bytesPerRow: pixels * 4, space: colorSpace, bitmapInfo: format) else { return source }
        let scale = CGFloat(pixels) / CGFloat(max(cropped.width, cropped.height))
        let width = CGFloat(cropped.width) * scale, height = CGFloat(cropped.height) * scale
        output.interpolationQuality = .high
        output.draw(cropped, in: CGRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2,
                                       width: width, height: height))
        // Thin outer strokes can disappear at menu-bar size. Fit once more
        // using the pixels that are actually visible at the target resolution.
        if let bytes = output.data?.assumingMemoryBound(to: UInt8.self) {
            var bounds = CGRect.null
            for y in 0..<pixels {
                for x in 0..<pixels where bytes[y * output.bytesPerRow + x * 4 + 3] > 38 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            if !bounds.isNull,
               (max(bounds.width, bounds.height) < CGFloat(pixels - 1)
                || abs(bounds.midX - CGFloat(pixels) / 2) > 1
                || abs(bounds.midY - CGFloat(pixels) / 2) > 1),
               let fitted = output.makeImage()?.cropping(to: bounds) {
                let factor = CGFloat(pixels) / max(bounds.width, bounds.height)
                let width = bounds.width * factor, height = bounds.height * factor
                output.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
                output.draw(fitted, in: CGRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2,
                                              width: width, height: height))
            }
        }
        // Resampling may overshoot premultiplied color channels at edges.
        // Reapply the same blue to the final alpha mask, including antialiasing.
        if let bytes = output.data?.assumingMemoryBound(to: UInt8.self) {
            for y in 0..<pixels {
                for x in 0..<pixels { colorize(bytes, at: y * output.bytesPerRow + x * 4) }
            }
        }
        guard let rendered = output.makeImage() else { return source }
        let representation = NSBitmapImageRep(cgImage: rendered)
        representation.size = NSSize(width: size, height: size)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        // Blue is baked into the pixels, so AppKit must not recolor this image.
        image.isTemplate = false
        menuBarImages[key] = image
        return image
    }

    static func artwork(for provider: ProviderQuota.Provider) -> Artwork? {
        switch provider {
        case .claude, .codex:
            return nil
        case .cursor:
            return Artwork(resourceName: "cursor", isTemplate: true)
        case .grok:
            return Artwork(resourceName: "grok", isTemplate: true)
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
        case .alibabaTokenPlan:
            return Artwork(resourceName: "bailian", isTemplate: false)
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

    static func claudeResourceURL() -> URL? {
        if let bundled = AppResourceBundle.bundle.url(forResource: "claude", withExtension: "png") {
            return bundled
        }
        #if DEBUG
        // Match the other providers' source-asset lookup in SwiftPM tests.
        let sourceResource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/claude.png")
        if FileManager.default.fileExists(atPath: sourceResource.path) {
            return sourceResource
        }
        #endif
        return nil
    }

    private static func claudeImage() -> NSImage {
        claudeResourceURL()
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(
                systemSymbolName: "questionmark.circle",
                accessibilityDescription: ProviderQuota.Provider.claude.rawValue
            )
            ?? NSImage(size: NSSize(width: 32, height: 32))
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

    static func monochromeImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(flower(in: rect).cgPath)
            context.fillPath()
            context.setBlendMode(.clear)
            context.addPath(prompt(in: rect).cgPath)
            context.setLineWidth(min(rect.width, rect.height) * promptStrokeRatio)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
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

/// Original neutral mark for user-configured services; not a vendor logo.
/// One vector drawing serves both SwiftUI cards and AppKit status attachments.
enum GenericRobotGlyph {
    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width, y: rect.height)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(CGPath(roundedRect: CGRect(x: 0.12, y: 0.26, width: 0.76, height: 0.60),
                                   cornerWidth: 0.15, cornerHeight: 0.15, transform: nil))
            context.fillPath()
            context.fill(CGRect(x: 0.46, y: 0.13, width: 0.08, height: 0.18))
            context.fillEllipse(in: CGRect(x: 0.41, y: 0.05, width: 0.18, height: 0.18))
            context.setBlendMode(.clear)
            for x in [0.29, 0.59] {
                context.fillEllipse(in: CGRect(x: x, y: 0.44, width: 0.12, height: 0.14))
            }
            context.fill(CGRect(x: 0.34, y: 0.68, width: 0.32, height: 0.06))
            return true
        }
        image.isTemplate = true
        return image
    }
}
