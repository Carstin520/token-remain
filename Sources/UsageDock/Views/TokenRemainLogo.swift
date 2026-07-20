import AppKit
import SwiftUI

enum TokenRemainLogoState: String, CaseIterable {
    case excitedStars = "100-excited-stars"
    case happyCarets = "90-happy-carets"
    case sparkle = "80-sparkle"
    case calmDots = "70-calm-dots"
    case focusedBars = "60-focused-bars"
    case neutralDashes = "50-neutral-dashes"
    case worriedSlants = "40-worried-slants"
    case tenseChevrons = "30-tense-chevrons"
    case dizzySpirals = "20-dizzy-spirals"
    case cryingWarning = "10-crying-warning"
    case offline = "0-offline-x"

    static func resolve(remainingPercent: Double?) -> Self {
        guard let remainingPercent else { return .neutralDashes }

        switch min(max(remainingPercent, 0), 100) {
        case 96...: return .excitedStars
        case 86...: return .happyCarets
        case 76...: return .sparkle
        case 66...: return .calmDots
        case 56...: return .focusedBars
        case 46...: return .neutralDashes
        case 36...: return .worriedSlants
        case 26...: return .tenseChevrons
        case 16...: return .dizzySpirals
        case 0.5...: return .cryingWarning
        default: return .offline
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .excitedStars: return "额度充足，兴奋"
        case .happyCarets: return "额度充足，开心"
        case .sparkle: return "额度健康，精神"
        case .calmDots: return "额度健康，平稳"
        case .focusedBars: return "额度适中，专注"
        case .neutralDashes: return "额度过半，平淡"
        case .worriedSlants: return "额度偏低，担忧"
        case .tenseChevrons: return "额度较低，紧张"
        case .dizzySpirals: return "额度很低，晕厥"
        case .cryingWarning: return "额度即将耗尽，焦虑"
        case .offline: return "额度已耗尽"
        }
    }

    /// AppKit is the narrow bridge used by the dynamic Dock icon. The same
    /// vector renderer also supplies SwiftUI, so no raster-state assets are
    /// downsampled at runtime.
    func image(size: CGFloat = 1024) -> NSImage {
        TokenRemainLogoArtwork.image(for: self, size: size)
    }
}

struct TokenRemainLogo: View {
    let remainingPercent: Double?

    private var state: TokenRemainLogoState {
        .resolve(remainingPercent: remainingPercent)
    }

    var body: some View {
        Image(nsImage: state.image(size: 256))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let remainingPercent else {
            return "Token Remain，等待额度数据"
        }
        return "Token Remain，剩余 \(Int(remainingPercent.rounded()))%，\(state.accessibilityDescription)"
    }
}

private enum TokenRemainLogoArtwork {
    private static let imageCache = NSCache<NSString, NSImage>()
    private static let navyTop = NSColor(srgbRed: 0.075, green: 0.095, blue: 0.27, alpha: 1)
    private static let navyBottom = NSColor(srgbRed: 0.018, green: 0.028, blue: 0.12, alpha: 1)
    private static let violet = NSColor(srgbRed: 0.43, green: 0.20, blue: 1.0, alpha: 1)
    private static let violetLight = NSColor(srgbRed: 0.61, green: 0.34, blue: 1.0, alpha: 1)
    private static let cyan = NSColor(srgbRed: 0.08, green: 0.82, blue: 0.93, alpha: 1)
    private static let orange = NSColor(srgbRed: 1.0, green: 0.31, blue: 0.015, alpha: 1)
    private static let orangeLight = NSColor(srgbRed: 1.0, green: 0.52, blue: 0.05, alpha: 1)

    static func image(for state: TokenRemainLogoState, size: CGFloat) -> NSImage {
        let cacheKey = "\(state.rawValue)-\(Int(size.rounded()))" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        let dimensions = NSSize(width: size, height: size)
        let image = NSImage(size: dimensions, flipped: true) { rect in
            guard let graphics = NSGraphicsContext.current else {
                return false
            }

            graphics.shouldAntialias = true
            graphics.imageInterpolation = .high
            draw(in: rect, state: state)
            return true
        }
        image.isTemplate = false
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func draw(in rect: NSRect, state: TokenRemainLogoState) {
        let side = min(rect.width, rect.height)

        func frame(
            _ x: CGFloat,
            _ y: CGFloat,
            _ width: CGFloat,
            _ height: CGFloat
        ) -> NSRect {
            NSRect(
                x: rect.minX + x * side,
                y: rect.minY + y * side,
                width: width * side,
                height: height * side
            )
        }

        NSColor.clear.setFill()
        rect.fill()

        let outerRect = frame(0.055, 0.055, 0.89, 0.89)
        let outer = NSBezierPath(
            roundedRect: outerRect,
            xRadius: side * 0.205,
            yRadius: side * 0.205
        )

        NSGraphicsContext.saveGraphicsState()
        outer.addClip()
        NSGradient(starting: navyTop, ending: navyBottom)?
            .draw(in: outerRect, angle: -90)

        let reservoirRect = frame(0.055, 0.745, 0.89, 0.20)
        NSGradient(starting: orangeLight, ending: orange)?
            .draw(in: reservoirRect, angle: -90)

        let glassHighlight = NSBezierPath(
            roundedRect: frame(0.075, 0.072, 0.85, 0.45),
            xRadius: side * 0.18,
            yRadius: side * 0.18
        )
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0.12), 0),
            (NSColor.clear, 1)
        )?.draw(in: glassHighlight, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        violetLight.withAlphaComponent(0.9).setStroke()
        outer.lineWidth = side * 0.018
        outer.stroke()

        // Smooth robot silhouette: the same recognizable antenna, ear pods,
        // visor, and base as the former pixel artwork, without staircase edges.
        let base = NSBezierPath(
            roundedRect: frame(0.335, 0.675, 0.33, 0.085),
            xRadius: side * 0.024,
            yRadius: side * 0.024
        )
        violet.withAlphaComponent(0.72).setFill()
        base.fill()

        let leftEar = NSBezierPath(
            roundedRect: frame(0.145, 0.445, 0.10, 0.205),
            xRadius: side * 0.045,
            yRadius: side * 0.045
        )
        let rightEar = NSBezierPath(
            roundedRect: frame(0.755, 0.445, 0.10, 0.205),
            xRadius: side * 0.045,
            yRadius: side * 0.045
        )
        NSGradient(starting: violetLight, ending: violet)?
            .draw(in: leftEar, angle: 0)
        NSGradient(starting: violet, ending: violetLight)?
            .draw(in: rightEar, angle: 0)

        let antennaStem = NSBezierPath(
            roundedRect: frame(0.477, 0.265, 0.046, 0.125),
            xRadius: side * 0.018,
            yRadius: side * 0.018
        )
        violet.setFill()
        antennaStem.fill()

        let antennaCap = NSBezierPath(
            roundedRect: frame(0.445, 0.245, 0.11, 0.052),
            xRadius: side * 0.026,
            yRadius: side * 0.026
        )
        violetLight.setFill()
        antennaCap.fill()

        let antennaLight = NSBezierPath(
            ovalIn: frame(0.487, 0.318, 0.026, 0.026)
        )
        cyan.setFill()
        antennaLight.fill()

        let headRect = frame(0.225, 0.365, 0.55, 0.35)
        let head = NSBezierPath(
            roundedRect: headRect,
            xRadius: side * 0.085,
            yRadius: side * 0.085
        )
        navyBottom.setFill()
        head.fill()
        violetLight.setStroke()
        head.lineWidth = side * 0.032
        head.stroke()

        drawFace(state, in: rect, side: side)
    }

    private static func drawFace(
        _ state: TokenRemainLogoState,
        in rect: NSRect,
        side: CGFloat
    ) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * side, y: rect.minY + y * side)
        }

        let left = point(0.385, 0.535)
        let right = point(0.615, 0.535)
        let stroke = side * 0.031

        func line(_ points: [NSPoint], width: CGFloat = stroke) {
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            points.dropFirst().forEach(path.line(to:))
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            orange.setStroke()
            path.stroke()
        }

        func dot(at center: NSPoint, radius: CGFloat = 0.022) {
            orange.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - side * radius,
                    y: center.y - side * radius,
                    width: side * radius * 2,
                    height: side * radius * 2
                )
            ).fill()
        }

        func star(at center: NSPoint) {
            line([
                point(center.x / side - 0.038, center.y / side),
                point(center.x / side + 0.038, center.y / side)
            ], width: stroke * 0.72)
            line([
                point(center.x / side, center.y / side - 0.038),
                point(center.x / side, center.y / side + 0.038)
            ], width: stroke * 0.72)
        }

        switch state {
        case .excitedStars:
            star(at: left)
            star(at: right)
        case .happyCarets:
            line([point(0.34, 0.56), point(0.385, 0.51), point(0.43, 0.56)])
            line([point(0.57, 0.56), point(0.615, 0.51), point(0.66, 0.56)])
        case .sparkle:
            star(at: left)
            dot(at: right, radius: 0.027)
        case .calmDots:
            dot(at: left)
            dot(at: right)
        case .focusedBars:
            line([point(0.34, 0.535), point(0.43, 0.535)])
            line([point(0.57, 0.535), point(0.66, 0.535)])
        case .neutralDashes:
            line([point(0.355, 0.54), point(0.415, 0.54)])
            line([point(0.585, 0.54), point(0.645, 0.54)])
        case .worriedSlants:
            line([point(0.345, 0.51), point(0.425, 0.565)])
            line([point(0.575, 0.565), point(0.655, 0.51)])
        case .tenseChevrons:
            line([point(0.34, 0.52), point(0.385, 0.57), point(0.43, 0.52)])
            line([point(0.57, 0.52), point(0.615, 0.57), point(0.66, 0.52)])
        case .dizzySpirals:
            drawSpiral(center: left, side: side)
            drawSpiral(center: right, side: side)
        case .cryingWarning:
            line([point(0.335, 0.50), point(0.435, 0.50)])
            line([point(0.385, 0.50), point(0.385, 0.59)])
            line([point(0.565, 0.50), point(0.665, 0.50)])
            line([point(0.615, 0.50), point(0.615, 0.59)])
        case .offline:
            line([point(0.35, 0.50), point(0.42, 0.57)])
            line([point(0.42, 0.50), point(0.35, 0.57)])
            line([point(0.58, 0.50), point(0.65, 0.57)])
            line([point(0.65, 0.50), point(0.58, 0.57)])
        }
    }

    private static func drawSpiral(center: NSPoint, side: CGFloat) {
        let path = NSBezierPath()
        let turns: CGFloat = 1.65
        let steps = 32

        for index in 0...steps {
            let progress = CGFloat(index) / CGFloat(steps)
            let angle = progress * turns * 2 * .pi
            let radius = side * (0.008 + progress * 0.042)
            let point = NSPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            index == 0 ? path.move(to: point) : path.line(to: point)
        }

        path.lineWidth = side * 0.022
        path.lineCapStyle = .round
        orange.setStroke()
        path.stroke()
    }
}
