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

    func image(
        size: CGFloat = 1024,
        tone: TokenRemainLogoTone = .neutral,
        remainingPercent: Double? = nil
    ) -> NSImage {
        TokenRemainLogoArtwork.image(
            for: self,
            tone: tone,
            remainingPercent: remainingPercent,
            size: size
        )
    }
}

enum TokenRemainLogoMeter {
    static let segmentCount = 10

    static func filledSegments(remainingPercent: Double?) -> Int? {
        guard let remainingPercent else { return nil }
        let clamped = min(max(remainingPercent, 0), 100)
        return Int((clamped / 100 * Double(segmentCount)).rounded())
    }
}

/// The logo hue communicates the provider driving the current state. Usage
/// only overrides that identity color when the selected session is critical.
enum TokenRemainLogoTone: Equatable {
    case neutral
    case provider(ProviderQuota.Provider)
    case critical

    static func resolve(
        provider: ProviderQuota.Provider?,
        remainingPercent: Double?
    ) -> Self {
        if let remainingPercent, remainingPercent < 10 {
            return .critical
        }
        guard let provider else { return .neutral }
        return .provider(provider)
    }

    var color: Color {
        switch self {
        case .neutral:
            return DashboardTheme.violet
        case .critical:
            return DashboardTheme.danger
        case .provider(.claude):
            return DashboardTheme.claudeBrand
        case .provider(.codex):
            return DashboardTheme.codexBrand
        case .provider(let provider):
            return DashboardTheme.quotaAccent(for: provider, remainingPercent: 100)
        }
    }

    fileprivate var cacheKey: String {
        switch self {
        case .neutral: return "neutral"
        case .critical: return "critical"
        case .provider(let provider): return provider.rawValue
        }
    }
}

struct TokenRemainLogo: View {
    let remainingPercent: Double?
    let provider: ProviderQuota.Provider?

    init(
        remainingPercent: Double?,
        provider: ProviderQuota.Provider? = nil
    ) {
        self.remainingPercent = remainingPercent
        self.provider = provider
    }

    private var state: TokenRemainLogoState {
        .resolve(remainingPercent: remainingPercent)
    }

    private var tone: TokenRemainLogoTone {
        .resolve(provider: provider, remainingPercent: remainingPercent)
    }

    var body: some View {
        Image(nsImage: state.image(
            size: 256,
            tone: tone,
            remainingPercent: remainingPercent
        ))
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let remainingPercent else {
            return "TokenRemain，等待额度数据"
        }
        let providerName = provider.map { "，由\($0.displayName)决定" } ?? ""
        return "TokenRemain，剩余 \(Int(remainingPercent.rounded()))%\(providerName)，\(state.accessibilityDescription)"
    }
}

private enum TokenRemainLogoArtwork {
    private static let imageCache = NSCache<NSString, NSImage>()
    private static let tileTop = NSColor(srgbRed: 0.055, green: 0.071, blue: 0.18, alpha: 1)
    private static let tileBottom = NSColor(srgbRed: 0.018, green: 0.026, blue: 0.075, alpha: 1)
    private static let facePlate = NSColor(srgbRed: 0.018, green: 0.028, blue: 0.10, alpha: 1)
    private static let robotBody = NSColor(srgbRed: 0.43, green: 0.20, blue: 1.0, alpha: 1)
    private static let robotEye = NSColor(srgbRed: 0.08, green: 0.82, blue: 0.93, alpha: 1)

    static func image(
        for state: TokenRemainLogoState,
        tone: TokenRemainLogoTone,
        remainingPercent: Double?,
        size: CGFloat
    ) -> NSImage {
        let meterLevel = TokenRemainLogoMeter.filledSegments(remainingPercent: remainingPercent)
        let meterKey = meterLevel.map(String.init) ?? "unknown"
        let cacheKey = "\(state.rawValue)-\(tone.cacheKey)-\(meterKey)-\(Int(size.rounded()))" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        let dimensions = NSSize(width: size, height: size)
        let image = NSImage(size: dimensions, flipped: true) { rect in
            guard let graphics = NSGraphicsContext.current else { return false }
            graphics.shouldAntialias = false
            graphics.imageInterpolation = .none
            draw(
                in: rect,
                state: state,
                tone: tone,
                meterLevel: meterLevel
            )
            return true
        }
        image.isTemplate = false
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func draw(
        in rect: NSRect,
        state: TokenRemainLogoState,
        tone: TokenRemainLogoTone,
        meterLevel: Int?
    ) {
        let side = min(rect.width, rect.height)
        let accent = NSColor(tone.color)
        func frame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(
                x: rect.minX + x * side,
                y: rect.minY + y * side,
                width: width * side,
                height: height * side
            )
        }

        NSColor.clear.setFill()
        rect.fill()

        let tileRect = frame(0.055, 0.055, 0.89, 0.89)
        let tile = NSBezierPath(
            roundedRect: tileRect,
            xRadius: side * 0.19,
            yRadius: side * 0.19
        )

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSGradient(starting: tileTop, ending: tileBottom)?.draw(in: tileRect, angle: -90)

        // Quiet pixel highlights keep the icon aligned with the Dashboard mark
        // without competing with the Orbit silhouette.
        accent.withAlphaComponent(0.13).setFill()
        frame(0.12, 0.12, 0.07, 0.07).fill()
        frame(0.81, 0.18, 0.045, 0.045).fill()
        NSGraphicsContext.restoreGraphicsState()

        accent.setStroke()
        tile.lineWidth = side * 0.018
        tile.stroke()

        drawRobot(in: rect, state: state, side: side)
        drawQuotaMeter(in: rect, side: side, accent: accent, filledSegments: meterLevel)
    }

    private static func drawRobot(
        in rect: NSRect,
        state: TokenRemainLogoState,
        side: CGFloat
    ) {
        let matrix = PixelRobotMark.matrix(face: PixelRobotMark.face(for: state))
        let cellSize = side * 0.039
        let gridWidth = cellSize * CGFloat(PixelRobotMark.columns)
        let originX = rect.midX - gridWidth / 2
        let originY = rect.minY + side * 0.145

        for (rowIndex, row) in matrix.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                let color: NSColor?
                switch cell {
                case .empty: color = nil
                case .body: color = robotBody
                case .bodyDim: color = robotBody.withAlphaComponent(0.58)
                case .cap: color = NSColor(DashboardTheme.text)
                case .signal: color = robotEye
                case .plate: color = facePlate
                case .eye: color = robotEye
                case .glow: color = robotEye.withAlphaComponent(0.48)
                }
                guard let color else { continue }
                color.setFill()
                NSRect(
                    x: originX + CGFloat(columnIndex) * cellSize,
                    y: originY + CGFloat(rowIndex) * cellSize,
                    width: cellSize,
                    height: cellSize
                ).fill()
            }
        }
    }

    private static func drawQuotaMeter(
        in rect: NSRect,
        side: CGFloat,
        accent: NSColor,
        filledSegments: Int?
    ) {
        let segmentCount = TokenRemainLogoMeter.segmentCount
        let totalWidth = side * 0.66
        let gap = side * 0.012
        let segmentWidth = (totalWidth - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount)
        let height = side * 0.028
        let originX = rect.midX - totalWidth / 2
        let originY = rect.minY + side * 0.84

        for index in 0..<segmentCount {
            let segment = NSRect(
                x: originX + CGFloat(index) * (segmentWidth + gap),
                y: originY,
                width: segmentWidth,
                height: height
            )
            (index < (filledSegments ?? 0)
                ? accent
                : NSColor.white.withAlphaComponent(0.11)).setFill()
            segment.fill()
        }
    }
}
