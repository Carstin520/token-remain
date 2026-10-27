import AppKit
import Foundation
import ImageIO

@main enum RenderIcons {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("usage: render-icons OUTPUT_DIR NATIVE_LIGHTING_DIR") }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let lighting = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for variant in DotRingIconArtwork.Variant.allCases {
            let file = lighting.appendingPathComponent("\(variant.rawValue)-macos-default.png")
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let material = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                fatalError("Missing native material source: \(file.path)")
            }
            for (appearance, name) in [(DotRingIconArtwork.Appearance.standard, "default"), (.tinted, "tinted")] {
                let image = DotRingIconArtwork.cgImage(size: 1024, variant: variant, litCount: variant.staticLitCount,
                    style: .tile, appearance: appearance, materialHead: material)
                try DotRingIconArtwork.writePNG(image, to: root.appendingPathComponent("\(variant.rawValue)-\(name)-1024.png"))
            }
            for size in [16, 24, 32, 48, 64, 128, 256, 512, 1024] {
                for (style, suffix) in [(DotRingIconArtwork.Style.tile, "tile"), (.dockTile, "dock")] {
                    let image = DotRingIconArtwork.cgImage(size: size, variant: variant, litCount: variant.staticLitCount,
                        style: style, materialHead: material)
                    try DotRingIconArtwork.writePNG(image, to: root.appendingPathComponent("\(variant.rawValue)-\(suffix)-\(size).png"))
                }
            }
            if variant == .full {
                for percent in [50, 60, 80, 90, 100] {
                    let image = DotRingIconArtwork.cgImage(size: 1024, variant: variant,
                        litCount: DotRingIconArtwork.litCount(remainingPercent: Double(percent)),
                        style: .tile, materialHead: material)
                    try DotRingIconArtwork.writePNG(image, to: root.appendingPathComponent("full-\(percent)-1024.png"))
                }
            }
        }
    }
}
