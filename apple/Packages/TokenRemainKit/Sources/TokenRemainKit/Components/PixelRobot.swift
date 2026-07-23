import SwiftUI

/// The 11 mood thresholds ported verbatim from `TokenRemainLogoState.resolve`.
/// Every threshold keeps its own eye expression, matching the macOS dynamic logo.
public enum RobotMoodState: String, Sendable, CaseIterable {
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

    public static func resolve(remainingPercent: Double?) -> Self {
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

    public var accessibilityDescription: String {
        switch self {
        case .excitedStars: return TRL10n.t("robot.100")
        case .happyCarets: return TRL10n.t("robot.90")
        case .sparkle: return TRL10n.t("robot.80")
        case .calmDots: return TRL10n.t("robot.70")
        case .focusedBars: return TRL10n.t("robot.60")
        case .neutralDashes: return TRL10n.t("robot.50")
        case .worriedSlants: return TRL10n.t("robot.40")
        case .tenseChevrons: return TRL10n.t("robot.30")
        case .dizzySpirals: return TRL10n.t("robot.20")
        case .cryingWarning: return TRL10n.t("robot.10")
        case .offline: return TRL10n.t("robot.0")
        }
    }

    /// One drawn face per quota band so the eyes remain a useful status signal.
    public var face: RobotFace {
        switch self {
        case .excitedStars: return .excitedStars
        case .happyCarets: return .happyCarets
        case .sparkle: return .sparkle
        case .calmDots: return .calmDots
        case .focusedBars: return .focusedBars
        case .neutralDashes: return .neutralDashes
        case .worriedSlants: return .worriedSlants
        case .tenseChevrons: return .tenseChevrons
        case .dizzySpirals: return .dizzySpirals
        case .cryingWarning: return .cryingWarning
        case .offline: return .offline
        }
    }
}

public enum RobotFace: Sendable, CaseIterable, Hashable {
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

    /// 8 wide × 3 tall eye window, blitted into the head's face plate.
    /// `e` = cyan eye, `g` = dim cyan glow, `.` = face plate.
    var eyes: [String] {
        switch self {
        case .excitedStars:
            return [".e....e.",
                    "eee..eee",
                    ".e....e."]
        case .happyCarets:
            return ["e.e..e.e",
                    ".e....e.",
                    "........"]
        case .sparkle:
            return [".e....e.",
                    "eee...e.",
                    ".e....g."]
        case .calmDots:
            return ["........",
                    ".ee..ee.",
                    ".gg..gg."]
        case .focusedBars:
            return ["........",
                    "eee..eee",
                    "........"]
        case .neutralDashes:
            return ["........",
                    ".ee..ee.",
                    "........"]
        case .worriedSlants:
            return ["e......e",
                    ".e....e.",
                    "..e..e.."]
        case .tenseChevrons:
            return ["........",
                    ".e....e.",
                    "e.e..e.e"]
        case .dizzySpirals:
            return ["eee..eee",
                    "e......e",
                    ".ee..ee."]
        case .cryingWarning:
            return [".e....e.",
                    "eee..eee",
                    ".g....g."]
        case .offline:
            return ["e.e..e.e",
                    ".e....e.",
                    "e.e..e.e"]
        }
    }

    var hasSweatPixel: Bool {
        self == .worriedSlants || self == .cryingWarning
    }
}

/// The canonical Orbit robot (2026-07-22 redesign) — a chunky rounded-square
/// head with a top antenna, side signal ears, little feet, and a **large inset
/// visor**: the 8×3 eye window sits centred in a 10×5 dark plate, so every mood's
/// eye shape reads clearly with a full pixel of dark margin on all sides. It is a
/// code-defined pixel matrix with integral cells, so the same mark stays crisp
/// from the 16pt Dynamic Island glyph up to the 96pt Overview hero.
public struct PixelRobot: View {
    public enum Cell: Sendable, Equatable {
        case empty, body, bodyDim, cap, signal, plate, eye, glow
    }

    private let remainingPercent: Double?
    private let size: CGFloat
    private let monochrome: Bool

    /// - Parameter monochrome: Lock Screen / accessory families render vibrant
    ///   monochrome; drawing in a single colour keeps the silhouette readable.
    public init(remainingPercent: Double?, size: CGFloat, monochrome: Bool = false) {
        self.remainingPercent = remainingPercent
        self.size = size
        self.monochrome = monochrome
    }

    public var state: RobotMoodState { .resolve(remainingPercent: remainingPercent) }

    // The matrix is pure data, so it stays off the main actor and can be asserted
    // directly in tests without a renderer.
    public nonisolated static let columns = 16
    public nonisolated static let rows = 16

    /// Orbit outline. `#` body, `d` dim (mouth slot / feet shadow), `p` antenna
    /// cap, `s` signal ear, `x` dark visor plate. The visor spans rows 5…9 ×
    /// cols 3…12 — one full cell of margin around the 8×3 eye window.
    private nonisolated static let head = [
        ".......pp.......",
        ".......##.......",
        "....########....",
        "..############..",
        ".##############.",
        ".##xxxxxxxxxx##.",
        "s##xxxxxxxxxx##s",
        "s##xxxxxxxxxx##s",
        "s##xxxxxxxxxx##s",
        ".##xxxxxxxxxx##.",
        ".##############.",
        ".###dddddddd###.",
        "..############..",
        "....##....##....",
        "....dd....dd....",
        "................"
    ]

    public nonisolated static func matrix(face: RobotFace) -> [[Cell]] {
        var grid: [[Cell]] = head.map { row in
            row.map { character in
                switch character {
                case "#": return Cell.body
                case "d": return Cell.bodyDim
                case "p": return Cell.cap
                case "s": return Cell.signal
                case "x": return Cell.plate
                default: return Cell.empty
                }
            }
        }
        // Blit the mood's eye window into the face plate at rows 6…8, cols 4…11.
        for (offset, line) in face.eyes.enumerated() {
            let row = 6 + offset
            for (column, character) in line.enumerated() {
                switch character {
                case "e": grid[row][4 + column] = .eye
                case "g": grid[row][4 + column] = .glow
                default: break
                }
            }
        }
        if face.hasSweatPixel {
            grid[3][14] = .glow
        }
        return grid
    }

    public var body: some View {
        let grid = Self.matrix(face: state.face)
        Canvas(rendersAsynchronously: false) { context, canvasSize in
            let cell = (canvasSize.width / CGFloat(Self.columns)).rounded(.down)
            guard cell >= 1 else { return }
            let originX = ((canvasSize.width - cell * CGFloat(Self.columns)) / 2).rounded()
            let originY = ((canvasSize.height - cell * CGFloat(Self.rows)) / 2).rounded()
            for (rowIndex, row) in grid.enumerated() {
                for (columnIndex, value) in row.enumerated() {
                    guard let color = color(for: value) else { continue }
                    // Integral rects only — no antialiased edges.
                    let rect = CGRect(
                        x: originX + CGFloat(columnIndex) * cell,
                        y: originY + CGFloat(rowIndex) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size * CGFloat(Self.rows) / CGFloat(Self.columns))
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private func color(for cell: Cell) -> Color? {
        if monochrome {
            switch cell {
            case .empty: return nil
            case .plate: return nil
            case .bodyDim, .glow: return TRTheme.text.opacity(0.45)
            case .body, .cap, .signal, .eye: return TRTheme.text
            }
        }
        switch cell {
        case .empty: return nil
        case .body: return TRTheme.violet
        case .bodyDim: return TRTheme.violetDim
        case .cap: return TRTheme.text
        case .signal: return TRTheme.cyan
        case .plate: return TRTheme.surface2
        case .eye: return TRTheme.cyan
        case .glow: return TRTheme.cyanDim
        }
    }

    public var accessibilityLabel: String {
        guard let remainingPercent else { return TRL10n.t("robot.a11y.waiting") }
        return TRL10n.f(
            "robot.a11y.value",
            Int(remainingPercent.rounded()),
            state.accessibilityDescription
        )
    }
}

#Preview("Robot moods") {
    HStack(spacing: 12) {
        ForEach([100.0, 80.0, 46.0, 30.0, 0.0], id: \.self) { value in
            PixelRobot(remainingPercent: value, size: 64)
        }
    }
    .padding()
    .background(TRTheme.ink)
}
