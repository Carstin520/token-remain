import SwiftUI

/// The canonical Orbit robot (2026-07-22 redesign, shared with the mobile
/// `PixelRobot`): a chunky rounded-square head with a top antenna, side signal
/// ears, little feet, and a large inset visor — the 8×3 eye window sits centred
/// in a 10×5 dark plate so every mood's eye shape reads clearly.
/// This standalone form has no app-icon tile or wordmark.
struct PixelRobotMark: View {
    enum Cell: Equatable {
        case empty
        case body
        case bodyDim
        case cap
        case signal
        case plate
        case eye
        case glow
    }

    enum Face: CaseIterable, Equatable {
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

        fileprivate var eyes: [String] {
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

        fileprivate var hasSweatPixel: Bool {
            self == .worriedSlants || self == .cryingWarning
        }
    }

    static let columns = 16
    static let rows = 16

    private static let head = [
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

    let remainingPercent: Double?

    private var state: TokenRemainLogoState {
        .resolve(remainingPercent: remainingPercent)
    }

    static func face(for state: TokenRemainLogoState) -> Face {
        switch state {
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

    static func matrix(face: Face) -> [[Cell]] {
        var grid = head.map { row in
            row.map { character -> Cell in
                switch character {
                case "#": return .body
                case "d": return .bodyDim
                case "p": return .cap
                case "s": return .signal
                case "x": return .plate
                default: return .empty
                }
            }
        }

        for (rowOffset, line) in face.eyes.enumerated() {
            for (columnOffset, character) in line.enumerated() {
                switch character {
                case "e": grid[6 + rowOffset][4 + columnOffset] = .eye
                case "g": grid[6 + rowOffset][4 + columnOffset] = .glow
                default: break
                }
            }
        }
        if face.hasSweatPixel {
            grid[3][14] = .glow
        }
        return grid
    }

    var body: some View {
        let face = Self.face(for: state)
        let grid = Self.matrix(face: face)

        Canvas(rendersAsynchronously: false) { context, size in
            let cellSize = min(
                size.width / CGFloat(Self.columns),
                size.height / CGFloat(Self.rows)
            ).rounded(.down)
            guard cellSize >= 1 else { return }

            let originX = ((size.width - cellSize * CGFloat(Self.columns)) / 2).rounded()
            let originY = ((size.height - cellSize * CGFloat(Self.rows)) / 2).rounded()
            for (rowIndex, row) in grid.enumerated() {
                for (columnIndex, cell) in row.enumerated() {
                    guard let color = color(for: cell) else { continue }
                    let rect = CGRect(
                        x: originX + CGFloat(columnIndex) * cellSize,
                        y: originY + CGFloat(rowIndex) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private func color(for cell: Cell) -> Color? {
        switch cell {
        case .empty: return nil
        case .body: return DashboardTheme.violet
        case .bodyDim: return DashboardTheme.violetDim
        case .cap: return DashboardTheme.text
        case .signal: return DashboardTheme.cyan
        case .plate: return DashboardTheme.surface2
        case .eye: return DashboardTheme.cyan
        case .glow: return DashboardTheme.cyanDim
        }
    }

    private var accessibilityLabel: String {
        guard let remainingPercent else {
            return "TokenRemain，等待额度数据"
        }
        return "TokenRemain，剩余 \(Int(remainingPercent.rounded()))%，\(state.accessibilityDescription)"
    }
}
