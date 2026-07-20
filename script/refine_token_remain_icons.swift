#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasSize = NSSize(width: 1024, height: 1024)
private let iconRect = NSRect(x: 70, y: 72, width: 884, height: 884)

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

private func render(sourceURL: URL, destinationURL: URL) throws {
    guard let source = NSImage(contentsOf: sourceURL) else {
        throw CocoaError(.fileReadCorruptFile)
    }
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
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    graphics.shouldAntialias = true

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    let outerShape = superellipse(in: iconRect)

    // A restrained ambient shadow gives the mark the same perceived weight as
    // neighboring macOS icons without turning it into a floating card.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
    outerShape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Preserve the robot, waterline, and emotion exactly; only place the
    // existing state inside a consistent macOS app-icon silhouette.
    NSGraphicsContext.saveGraphicsState()
    outerShape.addClip()
    source.draw(
        in: iconRect,
        from: NSRect(origin: .zero, size: source.size),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    NSGraphicsContext.restoreGraphicsState()

    // A single brand-violet rim defines the silhouette. No white highlight or
    // inset hairline is applied, so the icon never renders a light halo/fringe
    // around its edge over light or dark wallpapers. The rim is drawn slightly
    // inset from the clip boundary so it fully covers the anti-aliased art edge
    // and no bright interior sliver leaks past it.
    let rimShape = superellipse(in: iconRect.insetBy(dx: 4, dy: 4))
    NSColor(calibratedRed: 0.42, green: 0.28, blue: 1.0, alpha: 0.85).setStroke()
    rimShape.lineWidth = 10
    rimShape.stroke()

    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: destinationURL, options: .atomic)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: refine_token_remain_icons.swift <source-directory> <output-directory>\n".utf8)
    )
    exit(2)
}

let fileManager = FileManager.default
let sourceDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let sourceFiles = try fileManager.contentsOfDirectory(
    at: sourceDirectory,
    includingPropertiesForKeys: nil
).filter { $0.pathExtension.lowercased() == "png" }

guard !sourceFiles.isEmpty else {
    FileHandle.standardError.write(Data("no PNG state files found\n".utf8))
    exit(1)
}

for sourceFile in sourceFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    try render(
        sourceURL: sourceFile,
        destinationURL: outputDirectory.appendingPathComponent(sourceFile.lastPathComponent)
    )
    print("refined \(sourceFile.lastPathComponent)")
}
