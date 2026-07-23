#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasSize = NSSize(width: 1024, height: 1024)
private let macTileRect = NSRect(x: 70, y: 72, width: 884, height: 884)
private let columns = 16
private let rows = 16

private let tileTop = NSColor(srgbRed: 0.055, green: 0.071, blue: 0.18, alpha: 1)
private let tileBottom = NSColor(srgbRed: 0.018, green: 0.026, blue: 0.075, alpha: 1)
private let body = NSColor(srgbRed: 0.514, green: 0.341, blue: 0.961, alpha: 1)
private let bodyDim = NSColor(srgbRed: 0.302, green: 0.231, blue: 0.694, alpha: 1)
private let plate = NSColor(srgbRed: 0.051, green: 0.078, blue: 0.125, alpha: 1)
private let cyan = NSColor(srgbRed: 0.0, green: 0.804, blue: 0.910, alpha: 1)
private let cyanDim = NSColor(srgbRed: 0.169, green: 0.561, blue: 0.627, alpha: 1)
private let pale = NSColor(srgbRed: 0.914, green: 0.929, blue: 0.961, alpha: 1)

private enum Face: Equatable {
    case excitedStars
    case happyCarets
    case sparkle
    case calmDots
    case focusedBars
    case neutralDashes
    case worriedSlants
    case tenseChevrons
    case dizzySpirals
    case cryingWarning
    case offline

    var eyes: [String] {
        switch self {
        case .excitedStars:
            return [".e....e.", "eee..eee", ".e....e."]
        case .happyCarets:
            return ["e.e..e.e", ".e....e.", "........"]
        case .sparkle:
            return [".e....e.", "eee...e.", ".e....g."]
        case .calmDots:
            return ["........", ".ee..ee.", ".gg..gg."]
        case .focusedBars:
            return ["........", "eee..eee", "........"]
        case .neutralDashes:
            return ["........", ".ee..ee.", "........"]
        case .worriedSlants:
            return ["e......e", ".e....e.", "..e..e.."]
        case .tenseChevrons:
            return ["........", ".e....e.", "e.e..e.e"]
        case .dizzySpirals:
            return ["eee..eee", "e......e", ".ee..ee."]
        case .cryingWarning:
            return [".e....e.", "eee..eee", ".g....g."]
        case .offline:
            return ["e.e..e.e", ".e....e.", "e.e..e.e"]
        }
    }
}

private let orbit = [
    ".......pp.......",
    ".......##.......",
    "......####......",
    "....########....",
    "..############..",
    ".##############.",
    "###xxxxxxxxxx###",
    "#s#xxxxxxxxxx#s#",
    "###xxxxxxxxxx###",
    ".##xxxxxxxxxx##.",
    ".##############.",
    "..############..",
    "...##########...",
    ".....dddddd.....",
    "......####......",
    "......dddd......"
]

private let states: [(String, Face, Double)] = [
    ("0-offline-x.png", .offline, 0),
    ("10-crying-warning.png", .cryingWarning, 10),
    ("20-dizzy-spirals.png", .dizzySpirals, 20),
    ("30-tense-chevrons.png", .tenseChevrons, 30),
    ("40-worried-slants.png", .worriedSlants, 40),
    ("50-neutral-dashes.png", .neutralDashes, 50),
    ("60-focused-bars.png", .focusedBars, 60),
    ("70-calm-dots.png", .calmDots, 70),
    ("80-sparkle.png", .sparkle, 80),
    ("90-happy-carets.png", .happyCarets, 90),
    ("100-excited-stars.png", .excitedStars, 100)
]

private func superellipse(in rect: NSRect, exponent: CGFloat = 5.0) -> NSBezierPath {
    let path = NSBezierPath()
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radiusX = rect.width / 2
    let radiusY = rect.height / 2
    let steps = 240

    for index in 0...steps {
        let angle = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let point = NSPoint(
            x: center.x + radiusX * copysign(pow(abs(cosine), 2 / exponent), cosine),
            y: center.y + radiusY * copysign(pow(abs(sine), 2 / exponent), sine)
        )
        index == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

private func matrix(face: Face) -> [[Character]] {
    var grid = orbit.map(Array.init)
    for (rowOffset, line) in face.eyes.enumerated() {
        for (columnOffset, character) in line.enumerated() where character != "." {
            grid[6 + rowOffset][4 + columnOffset] = character
        }
    }
    if face == .worriedSlants || face == .cryingWarning {
        grid[4][14] = "g"
    }
    return grid
}

private func drawQuotaMeter(remainingPercent: Double, in rect: NSRect) {
    let segmentCount = 10
    let totalWidth = rect.width * 0.66
    let gap = rect.width * 0.012
    let segmentWidth = (totalWidth - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount)
    let height = rect.width * 0.028
    let originX = rect.midX - totalWidth / 2
    let originY = rect.minY + rect.height * 0.095
    let clamped = min(max(remainingPercent, 0), 100)
    let filled = Int((clamped / 100 * Double(segmentCount)).rounded())

    for index in 0..<segmentCount {
        let segment = NSRect(
            x: originX + CGFloat(index) * (segmentWidth + gap),
            y: originY,
            width: segmentWidth,
            height: height
        )
        (index < filled ? cyan : pale.withAlphaComponent(0.12)).setFill()
        segment.fill()
    }
}

private func color(for character: Character) -> NSColor? {
    switch character {
    case "#": return body
    case "d": return bodyDim
    case "p": return pale
    case "s": return cyan
    case "x": return plate
    case "e": return cyan
    case "g": return cyanDim
    default: return nil
    }
}

private func drawBackground(in rect: NSRect) {
    NSGradient(starting: tileTop, ending: tileBottom)?.draw(in: rect, angle: -90)

    body.withAlphaComponent(0.11).setFill()
    NSRect(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.12,
           width: rect.width * 0.055, height: rect.width * 0.055).fill()
    NSRect(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.20,
           width: rect.width * 0.035, height: rect.width * 0.035).fill()
}

private func drawRobot(face: Face, in bounds: NSRect) {
    let cell = floor(min(bounds.width / CGFloat(columns), bounds.height / CGFloat(rows)))
    let width = cell * CGFloat(columns)
    let height = cell * CGFloat(rows)
    let originX = bounds.midX - width / 2
    let originY = bounds.midY - height / 2

    for (rowIndex, row) in matrix(face: face).enumerated() {
        for (columnIndex, character) in row.enumerated() {
            guard let color = color(for: character) else { continue }
            color.setFill()
            NSRect(
                x: originX + CGFloat(columnIndex) * cell,
                y: originY + CGFloat(rows - 1 - rowIndex) * cell,
                width: cell,
                height: cell
            ).fill()
        }
    }
}

private func makeBitmap() throws -> (NSBitmapImageRep, NSGraphicsContext) {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width),
        pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return (bitmap, graphics)
}

private func write(
    _ bitmap: NSBitmapImageRep,
    to destinationURL: URL,
    removingAlpha: Bool = false
) throws {
    let output: NSBitmapImageRep
    if removingAlpha {
        guard let source = bitmap.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let width = source.width
        let height = source.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        output = NSBitmapImageRep(cgImage: flattened)
    } else {
        output = bitmap
    }

    guard let png = output.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: destinationURL, options: .atomic)
}

private func renderMacIcon(face: Face, remainingPercent: Double, destinationURL: URL) throws {
    let (bitmap, graphics) = try makeBitmap()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .none
    graphics.shouldAntialias = true

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    let tile = superellipse(in: macTileRect)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    tileTop.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    drawBackground(in: macTileRect)
    NSGraphicsContext.restoreGraphicsState()

    graphics.shouldAntialias = false
    drawRobot(face: face, in: NSRect(x: 200, y: 198, width: 624, height: 624))
    drawQuotaMeter(remainingPercent: remainingPercent, in: macTileRect)
    graphics.shouldAntialias = true
    let rim = superellipse(in: macTileRect.insetBy(dx: 4, dy: 4))
    body.withAlphaComponent(0.86).setStroke()
    rim.lineWidth = 10
    rim.stroke()

    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try write(bitmap, to: destinationURL)
}

private func renderSquareIcon(face: Face, remainingPercent: Double, destinationURL: URL) throws {
    let (bitmap, graphics) = try makeBitmap()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .none
    graphics.shouldAntialias = false

    drawBackground(in: NSRect(origin: .zero, size: canvasSize))
    drawRobot(face: face, in: NSRect(x: 160, y: 160, width: 704, height: 704))
    drawQuotaMeter(remainingPercent: remainingPercent, in: NSRect(origin: .zero, size: canvasSize))

    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try write(bitmap, to: destinationURL, removingAlpha: true)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data(
        "usage: refine_token_remain_icons.swift <design-state-directory> <mac-state-directory> <ios-app-icon>\n".utf8
    ))
    exit(2)
}

let fileManager = FileManager.default
let designDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let macStateDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let iOSAppIcon = URL(fileURLWithPath: arguments[3])
try fileManager.createDirectory(at: designDirectory, withIntermediateDirectories: true)
try fileManager.createDirectory(at: macStateDirectory, withIntermediateDirectories: true)
try fileManager.createDirectory(at: iOSAppIcon.deletingLastPathComponent(), withIntermediateDirectories: true)

for (fileName, face, remainingPercent) in states {
    try renderSquareIcon(
        face: face,
        remainingPercent: remainingPercent,
        destinationURL: designDirectory.appendingPathComponent(fileName)
    )
    try renderMacIcon(
        face: face,
        remainingPercent: remainingPercent,
        destinationURL: macStateDirectory.appendingPathComponent(fileName)
    )
    print("rendered Orbit state \(fileName)")
}

try renderSquareIcon(face: .calmDots, remainingPercent: 70, destinationURL: iOSAppIcon)
print("rendered Apple App Icon \(iOSAppIcon.path)")
