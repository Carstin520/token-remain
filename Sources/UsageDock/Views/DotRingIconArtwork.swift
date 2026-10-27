import AppKit
import ImageIO
import UniformTypeIdentifiers

/// O4-C tile geometry. Packaging and the live Dock share this renderer.
enum DotRingIconArtwork {
    enum Variant: String, CaseIterable {
        case full, medium, small
        static func resolve(pixelSize: CGFloat) -> Self {
            pixelSize < 32 ? .small : pixelSize < 64 ? .medium : .full
        }
        var dotCount: Int { self == .small ? 0 : self == .medium ? 10 : 20 }
        var staticLitCount: Int { self == .medium ? 8 : self == .full ? 15 : 0 }
    }
    enum Style { case bare, dockTile, tile }
    enum Appearance { case standard, tinted }
    static let tileFill = (red: 8.0 / 255, green: 20.0 / 255, blue: 49.0 / 255)
    static let tileInset: CGFloat = 100.0 / 1024
    static let tileCornerRadius: CGFloat = 185.4 / 1024

    static func litCount(remainingPercent: Double?, variant: Variant = .full) -> Int {
        guard let remainingPercent, remainingPercent.isFinite, remainingPercent > 0,
              variant.dotCount > 0 else { return 0 }
        let clamped = min(remainingPercent, 100)
        return min(variant.dotCount, max(1, Int((clamped / (variant == .medium ? 10 : 5)).rounded())))
    }

    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
            CGFloat((hex >> 16) & 255) / 255,
            CGFloat((hex >> 8) & 255) / 255,
            CGFloat(hex & 255) / 255, 1
        ])!
    }

    static func cgImage(
        size: Int, variant: Variant, litCount: Int, style: Style,
        appearance: Appearance = .standard, materialHead: CGImage? = nil
    ) -> CGImage {
        precondition(size > 0)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGImageAlphaInfo = style == .tile ? .noneSkipLast : .premultipliedLast
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4, space: space,
                                bitmapInfo: alpha.rawValue)!
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
        let whole = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let mono = appearance == .tinted
        if style == .dockTile {
            let frame = whole.insetBy(dx: 100, dy: 100)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil))
            context.clip()
            context.translateBy(x: 100, y: 100)
            context.scaleBy(x: 824.0 / 1024, y: 824.0 / 1024)
        }
        if style != .bare {
            context.setFillColor(color(mono ? 0x000000 : 0x081431))
            context.fill(whole)
        }
        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func fill(_ path: CGPath, _ hex: UInt32) {
            context.addPath(path); context.setFillColor(color(hex)); context.fillPath()
        }
        if variant != .small {
            let radius: CGFloat = variant == .medium ? 392 : 400
            let dot: CGFloat = variant == .medium ? 46 : 30
            for i in 0..<variant.dotCount {
                let angle = -Double.pi / 2 + Double(i) * 2 * Double.pi / Double(variant.dotCount)
                let x = 512 + radius * CGFloat(cos(angle)), y = 512 + radius * CGFloat(sin(angle))
                context.setFillColor(color(i < litCount ? (mono ? 0xFFFFFF : 0x3ECFE0) : (mono ? 0x333333 : 0x2B3754)))
                context.fillEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
            }
        }
        let small = variant == .small
        let antenna = small ? rounded(439, 201, 146, 88, 33) : rounded(459, 262, 106, 64, 24)
        let shell = small ? rounded(200, 270, 624, 552, 166) : rounded(286, 312, 452, 400, 120)
        let depth = rounded(286, 352, 452, 400, 120)
        fill(antenna, mono ? 0xD9D9D9 : 0xB7A9F7)
        if !small { fill(depth, mono ? 0x737373 : 0x5B4FB0) }
        fill(shell, mono ? 0xB3B3B3 : 0x8F7BF2)
        // The optional native lighting is copied only inside the exact head
        // silhouette. No system tile mask/bevel is baked into full-bleed PNGs.
        // Face and dots are repainted in sRGB, keeping their source colors exact.
        if let materialHead, !mono {
            context.saveGState()
            let mask = CGMutablePath(); mask.addPath(antenna); mask.addPath(shell)
            if !small { mask.addPath(depth) }
            context.addPath(mask); context.clip()
            context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(materialHead, in: whole)
            context.restoreGState()
        }
        fill(small ? rounded(291, 372, 442, 331, 91) : rounded(352, 386, 320, 240, 66), mono ? 0x000000 : 0x070B12)
        let eyeRadius: CGFloat = small ? 56 : variant == .medium ? 40 : 34
        let eyeY: CGFloat = small ? 538 : 506
        for eyeX: CGFloat in small ? [411, 613] : [439, 585] {
            context.setFillColor(color(mono ? 0xFFFFFF : 0x3ECFE0))
            context.fillEllipse(in: CGRect(x: eyeX - eyeRadius, y: eyeY - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2))
        }
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
