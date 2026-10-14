import AppKit
import SwiftUI

/// Head-only 3D pixel-pet artwork used for the live macOS Dock icon and any
/// large in-app brand presentation. The expression follows the lower provider;
/// each of the two independent meters carries its provider's color (Claude
/// orange and Codex blue by default — the user picks the pair in Settings).
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
    /// One meter on the head: which provider it belongs to and how much of the
    /// headline window is left. A slot without data draws no row.
    struct Slot: Equatable {
        let provider: ProviderQuota.Provider
        let remainingPercent: Double?
    }

    private struct MeterRow {
        let remainingPercent: Double
        let color: NSColor
    }

    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // 同一时刻活跃的表情/量表组合只有个位数;逐出后按需重绘即可,
        // 不能让一整天的配额漂移在内存里积累几百张位图。
        cache.countLimit = 12
        return cache
    }()
    private static let claudeColor = NSColor(srgbRed: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0, alpha: 1)
    private static let codexColor = NSColor(srgbRed: 75.0 / 255.0, green: 156.0 / 255.0, blue: 251.0 / 255.0, alpha: 1)
    private static let trackColor = NSColor(srgbRed: 29.0 / 255.0, green: 38.0 / 255.0, blue: 61.0 / 255.0, alpha: 0.96)
    private static let borderColor = NSColor(srgbRed: 69.0 / 255.0, green: 82.0 / 255.0, blue: 116.0 / 255.0, alpha: 0.9)

    /// Claude and Codex keep the meter colors the icon shipped with; every
    /// other provider uses its stable theme accent, the same hue its quota
    /// meters carry everywhere else in the app.
    static func meterColor(for provider: ProviderQuota.Provider) -> NSColor {
        switch provider {
        case .claude: return claudeColor
        case .codex: return codexColor
        default: return NSColor(DashboardTheme.accent(for: provider))
        }
    }

    /// The historical pairing, kept for callers that still think in it.
    static func slots(claudeRemaining: Double?, codexRemaining: Double?) -> [Slot] {
        [
            Slot(provider: .claude, remainingPercent: claudeRemaining),
            Slot(provider: .codex, remainingPercent: codexRemaining)
        ]
    }

    /// The expression follows whichever selected provider is lower.
    static func moodRemaining(_ slots: [Slot]) -> Double? {
        slots.compactMap(\.remainingPercent).min()
    }

    static func renderKey(claudeRemaining: Double?, codexRemaining: Double?) -> String {
        renderKey(slots: slots(claudeRemaining: claudeRemaining, codexRemaining: codexRemaining))
    }

    /// Stable identity of the artwork for a set of slots. Two equal keys
    /// always render pixel-identical images, so callers can skip redundant
    /// `applicationIconImage` assignments (each one forces a full Dock tile
    /// redraw even when the image object is unchanged).
    /// 每条量表的档位必须带上 provider 前缀:Claude 单条 45% 是橙色,
    /// Codex 单条 45% 是蓝色,光凭档位序列无法区分这两张图。
    static func renderKey(slots: [Slot]) -> String {
        let state = TokenRemainLogoState.resolve(remainingPercent: moodRemaining(slots))
        let levels = slots.map { slot -> String in
            guard let remaining = slot.remainingPercent else { return "\(slot.provider.rawValue)_" }
            let filled = TokenRemainLogoMeter.filledSegments(remainingPercent: remaining) ?? -1
            return "\(slot.provider.rawValue)\(filled)"
        }
        return (["head", state.rawValue] + levels).joined(separator: "-")
    }

    static func image(
        claudeRemaining: Double?,
        codexRemaining: Double?,
        size: CGFloat = 1024
    ) -> NSImage {
        image(
            slots: slots(claudeRemaining: claudeRemaining, codexRemaining: codexRemaining),
            size: size
        )
    }

    /// How the artwork sits on its canvas.
    enum Style: String {
        /// Transparent around the robot, for in-app brand presentations.
        case bare
        /// The running Dock icon. macOS 26+ draws the bundled Icon Composer
        /// icon (Resources/AppIcon.icon) on the system icon shape but shows an
        /// `applicationIconImage` exactly as given, so this draws the same
        /// navy shape itself; otherwise the icon loses its tile the moment the
        /// app launches.
        case dockTile
    }

    /// The Icon Composer fill of `Resources/AppIcon.icon`, sampled from the
    /// static master. A test keeps the two in step.
    static let dockTileFill = (red: 8.0 / 255, green: 20.0 / 255, blue: 49.0 / 255)

    /// Apple's macOS icon grid: an 824-point shape centred on a 1024 canvas.
    static let dockTileInset: CGFloat = 100.0 / 1024
    static let dockTileCornerRadius: CGFloat = 185.4 / 1024

    /// The master composes its art inside an older tile inset by this much;
    /// the Dock tile maps that square onto its own shape, as the `.icon`
    /// foreground layer does (script/extract_app_icon_foreground.swift).
    static let masterTileInset: CGFloat = 46.0 / 1024

    static func image(slots: [Slot], size: CGFloat = 1024, style: Style = .bare) -> NSImage {
        let moodRemaining = moodRemaining(slots)
        let state = TokenRemainLogoState.resolve(remainingPercent: moodRemaining)
        let rows = slots.compactMap { slot in
            slot.remainingPercent.map {
                MeterRow(remainingPercent: $0, color: meterColor(for: slot.provider))
            }
        }
        let key = renderKey(slots: slots)
        let cacheKey = "\(key)-\(style.rawValue)-\(Int(size.rounded()))" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        guard let source = sourceImage(for: state) else {
            return state.image(size: size, remainingPercent: moodRemaining)
        }

        let image = style == .dockTile
            ? renderDockTile(source: source, rows: rows, size: size)
            : render(source: source, rows: rows, size: size)
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

    private static func renderDockTile(
        source: NSImage,
        rows: [MeterRow],
        size: CGFloat
    ) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        return NSImage(size: dimensions, flipped: false) { rect in
            guard let graphics = NSGraphicsContext.current else { return false }
            graphics.shouldAntialias = true
            graphics.imageInterpolation = .high

            let body = rect.insetBy(dx: size * dockTileInset, dy: size * dockTileInset)
            let shape = NSBezierPath(
                roundedRect: body,
                xRadius: size * dockTileCornerRadius,
                yRadius: size * dockTileCornerRadius
            )
            // The master's tile square maps onto `body`; its full canvas is
            // that square grown back by the master's own inset.
            let masterScale = body.width / (1 - 2 * masterTileInset)
            let content = body.insetBy(
                dx: -masterScale * masterTileInset,
                dy: -masterScale * masterTileInset
            )
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor(
                srgbRed: dockTileFill.red,
                green: dockTileFill.green,
                blue: dockTileFill.blue,
                alpha: 1
            ).setFill()
            body.fill()
            source.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1)
            drawMeters(rows, in: content)
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

    /// The Dock-tile renderer with an injected source, since SwiftPM tests do
    /// not bundle the head-state PNGs.
    static func renderDockTileForTesting(_ source: NSImage, size: CGFloat) -> NSImage {
        renderDockTile(source: source, rows: [], size: size)
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
