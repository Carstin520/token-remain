import AppKit
import SwiftUI

/// Head-only 3D pixel-pet artwork used for the live macOS Dock icon and any
/// large in-app brand presentation. The expression follows the lower provider;
/// Claude remains orange and Codex remains blue in the two independent meters.
struct TokenRemainHeadLogo: View {
    let claudeRemaining: Double?
    let codexRemaining: Double?

    var body: some View {
        Image(nsImage: TokenRemainHeadLogoArtwork.image(
            claudeRemaining: claudeRemaining,
            codexRemaining: codexRemaining,
            size: 256
        ))
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let values = [
            claudeRemaining.map { "Claude \(Int($0.rounded()))%" },
            codexRemaining.map { "Codex \(Int($0.rounded()))%" }
        ].compactMap { $0 }
        let mood = TokenRemainLogoState.resolve(
            remainingPercent: [claudeRemaining, codexRemaining].compactMap { $0 }.min()
        )
        return values.isEmpty
            ? L10n.format("logo.accessibility.brand_state", mood.accessibilityDescription)
            : L10n.format(
                "logo.accessibility.brand_values_state",
                values.joined(separator: L10n.text("common.list_separator")),
                mood.accessibilityDescription
            )
    }
}

enum TokenRemainHeadLogoArtwork {
    private struct MeterRow {
        let remainingPercent: Double
        let color: NSColor
    }

    private static let imageCache = NSCache<NSString, NSImage>()
    private static let claudeColor = NSColor(srgbRed: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0, alpha: 1)
    private static let codexColor = NSColor(srgbRed: 75.0 / 255.0, green: 156.0 / 255.0, blue: 251.0 / 255.0, alpha: 1)
    private static let trackColor = NSColor(srgbRed: 29.0 / 255.0, green: 38.0 / 255.0, blue: 61.0 / 255.0, alpha: 0.96)
    private static let borderColor = NSColor(srgbRed: 69.0 / 255.0, green: 82.0 / 255.0, blue: 116.0 / 255.0, alpha: 0.9)

    static func image(
        claudeRemaining: Double?,
        codexRemaining: Double?,
        size: CGFloat = 1024
    ) -> NSImage {
        let moodRemaining = [claudeRemaining, codexRemaining].compactMap { $0 }.min()
        let state = TokenRemainLogoState.resolve(remainingPercent: moodRemaining)
        let rows = meterRows(claudeRemaining: claudeRemaining, codexRemaining: codexRemaining)
        let levels = rows.map { TokenRemainLogoMeter.filledSegments(remainingPercent: $0.remainingPercent) ?? -1 }
        let cacheKey = "head-\(state.rawValue)-\(levels.map(String.init).joined(separator: "-"))-\(Int(size.rounded()))" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        guard let source = sourceImage(for: state) else {
            return state.image(size: size, remainingPercent: moodRemaining)
        }

        let image = render(source: source, rows: rows, size: size)
        image.isTemplate = false
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func render(
        source: NSImage,
        rows: [MeterRow],
        size: CGFloat
    ) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        return NSImage(size: dimensions, flipped: false) { rect in
            guard let graphics = NSGraphicsContext.current else { return false }
            graphics.shouldAntialias = true
            graphics.imageInterpolation = .high

            let tileRect = rect.insetBy(dx: size * 0.045, dy: size * 0.045)
            let tile = NSBezierPath(
                roundedRect: tileRect,
                xRadius: size * 0.213,
                yRadius: size * 0.213
            )
            NSGraphicsContext.saveGraphicsState()
            tile.addClip()
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            drawMeters(rows, in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    private static func sourceImage(for state: TokenRemainLogoState) -> NSImage? {
        guard let url = AppResourceBundle.bundle.url(
            forResource: state.rawValue,
            withExtension: "png",
            subdirectory: "TokenRemainHeadStates"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Exercises the same unflipped AppKit renderer as the production Dock icon.
    static func renderSourceUprightForTesting(_ source: NSImage, size: CGFloat) -> NSImage {
        render(source: source, rows: [], size: size)
    }

    private static func meterRows(
        claudeRemaining: Double?,
        codexRemaining: Double?
    ) -> [MeterRow] {
        [
            claudeRemaining.map { MeterRow(remainingPercent: $0, color: claudeColor) },
            codexRemaining.map { MeterRow(remainingPercent: $0, color: codexColor) }
        ].compactMap { $0 }
    }

    private static func drawMeters(_ rows: [MeterRow], in rect: NSRect) {
        guard !rows.isEmpty else { return }
        let side = min(rect.width, rect.height)
        let segmentCount = 10
        let meterWidth = side * 0.63
        let gap = max(1, side * 0.008)
        let segmentWidth = (meterWidth - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount)
        let segmentHeight = max(2, side * 0.024)
        let originX = rect.midX - meterWidth / 2
        let startFromTop = side * (rows.count == 2 ? 0.837 : 0.862)
        let startY = rect.maxY - startFromTop - segmentHeight
        let rowGap = side * 0.049

        for (rowIndex, row) in rows.enumerated() {
            let filled = TokenRemainLogoMeter.filledSegments(
                remainingPercent: row.remainingPercent
            ) ?? 0
            let y = startY - CGFloat(rowIndex) * rowGap
            for segment in 0..<segmentCount {
                let segmentRect = NSRect(
                    x: originX + CGFloat(segment) * (segmentWidth + gap),
                    y: y,
                    width: segmentWidth,
                    height: segmentHeight
                )
                let path = NSBezierPath(
                    roundedRect: segmentRect,
                    xRadius: max(0.75, segmentHeight * 0.16),
                    yRadius: max(0.75, segmentHeight * 0.16)
                )
                (segment < filled ? row.color : trackColor).setFill()
                path.fill()
                borderColor.setStroke()
                path.lineWidth = max(0.5, side * 0.0015)
                path.stroke()
            }
        }
    }
}
