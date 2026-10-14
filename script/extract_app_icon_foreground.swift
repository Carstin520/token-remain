import AppKit
import CoreGraphics
import Foundation

// Cuts the static app icon master (robot head plus calm dual meters on a deep
// navy square) into the foreground layer of `Resources/AppIcon.icon`. Icon
// Composer draws the navy itself as the icon fill, so the layer must carry
// only the artwork: every pixel connected to the border whose color stays
// close to the border's navy becomes transparent. A flood fill, not a global
// color key, so the dark face display and the empty meter tracks inside the
// artwork are kept even where their color is near the background.
//
// usage: extract_app_icon_foreground.swift <master.png> <foreground.png>

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: extract_app_icon_foreground.swift <master.png> <foreground.png>\n".utf8))
    exit(2)
}

guard let source = NSImage(contentsOfFile: arguments[1]),
      let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read \(arguments[1])\n".utf8))
    exit(1)
}

let width = cgImage.width
let height = cgImage.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: bytesPerRow, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = y * bytesPerRow + x * 4
    return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
}

func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[y * bytesPerRow + x * 4 + 3]) }

// The master is already a pre-macOS 26 rounded tile: transparent outside its
// shape, opaque navy inside. Sample the navy along the middle row and column
// just inside the shape's edge, where nothing but background is drawn.
var samples: [(Int, Int, Int)] = []
for offset in 0..<(width / 8) {
    for (x, y) in [(offset, height / 2), (width - 1 - offset, height / 2), (width / 2, offset)]
    where alpha(x, y) == 255 {
        samples.append(rgb(x, y))
    }
}
guard !samples.isEmpty else {
    FileHandle.standardError.write(Data("no opaque background found near the edges\n".utf8))
    exit(1)
}
func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
let navy = (median(samples.map(\.0)), median(samples.map(\.1)), median(samples.map(\.2)))

// The master's background carries soft generation noise; this distance
// (Euclidean, 0–255 per channel) clears it while stopping at the robot
// outline and the meter frames.
let tolerance = Int(ProcessInfo.processInfo.environment["ICON_BG_TOLERANCE"] ?? "") ?? 28
func isBackground(_ x: Int, _ y: Int) -> Bool {
    // Outside the old tile shape, and its anti-aliased rim.
    if alpha(x, y) < 250 { return true }
    let (r, g, b) = rgb(x, y)
    let dr = r - navy.0, dg = g - navy.1, db = b - navy.2
    return dr * dr + dg * dg + db * db <= tolerance * tolerance
}

var visited = [Bool](repeating: false, count: width * height)
var stack: [(Int, Int)] = []
for x in 0..<width { stack.append((x, 0)); stack.append((x, height - 1)) }
for y in 0..<height { stack.append((0, y)); stack.append((width - 1, y)) }
while let (x, y) = stack.popLast() {
    guard x >= 0, y >= 0, x < width, y < height else { continue }
    let index = y * width + x
    guard !visited[index], isBackground(x, y) else { continue }
    visited[index] = true
    let i = y * bytesPerRow + x * 4
    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
    stack.append((x + 1, y)); stack.append((x - 1, y))
    stack.append((x, y + 1)); stack.append((x, y - 1))
}

guard let cutOut = context.makeImage() else { exit(1) }

// An Icon Composer canvas is the icon shape itself (the system adds the outer
// margin), while the master keeps its artwork inside the old tile. Map the old
// tile's square onto the whole canvas so the art keeps its proportions to the
// shape it sits on.
let tileInset = Int((Double(width) * 46 / 1024).rounded())
let tileRect = CGRect(x: tileInset, y: tileInset, width: width - 2 * tileInset, height: height - 2 * tileInset)
guard let tile = cutOut.cropping(to: tileRect),
      let canvas = CGContext(
          data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { exit(1) }
canvas.interpolationQuality = .high
canvas.draw(tile, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let output = canvas.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: output)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))
print(String(format: "navy fill srgb:%.5f,%.5f,%.5f", Double(navy.0) / 255, Double(navy.1) / 255, Double(navy.2) / 255))
