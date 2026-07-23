import ImageIO
import SwiftUI

/// The concept-10 full-body pet for the iPhone overview. The lower provider
/// selects the expression and a four-frame stepped idle motion keeps it alive.
public struct TokenRemainFullBodyRobot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let claudeRemaining: Double?
    private let codexRemaining: Double?
    private let size: CGFloat
    private let animated: Bool

    public init(
        claudeRemaining: Double?,
        codexRemaining: Double?,
        size: CGFloat,
        animated: Bool = true
    ) {
        self.claudeRemaining = claudeRemaining
        self.codexRemaining = codexRemaining
        self.size = size
        self.animated = animated
    }

    private var moodRemaining: Double? {
        [claudeRemaining, codexRemaining].compactMap { $0 }.min()
    }

    public var mood: RobotMoodState {
        .resolve(remainingPercent: moodRemaining)
    }

    public var body: some View {
        TimelineView(.animation(
            minimumInterval: 0.22,
            paused: !animated || reduceMotion
        )) { timeline in
            let pose = idlePose(at: timeline.date)
            artwork
                .offset(y: pose.offsetY)
                .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TokenRemain, \(mood.accessibilityDescription)")
    }

    @ViewBuilder
    private var artwork: some View {
        if let cgImage = Self.loadImage(named: "fullbody-\(mood.rawValue)") {
            Image(decorative: cgImage, scale: 1)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Color.clear
        }
    }

    private func idlePose(at date: Date) -> (offsetY: CGFloat, scaleX: CGFloat, scaleY: CGFloat) {
        guard animated, !reduceMotion else { return (0, 1, 1) }
        let frame = Int(date.timeIntervalSinceReferenceDate / 0.22) % 4
        switch frame {
        case 1: return (-1, 1.004, 0.996)
        case 2: return (-1, 1.008, 0.992)
        case 3: return (0, 1.004, 0.996)
        default: return (0, 1, 1)
        }
    }

    private static func loadImage(named name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

#Preview("Full-body usage moods") {
    HStack(spacing: 16) {
        TokenRemainFullBodyRobot(claudeRemaining: 82, codexRemaining: 46, size: 96)
        TokenRemainFullBodyRobot(claudeRemaining: 18, codexRemaining: 64, size: 96)
    }
    .padding()
    .background(TRTheme.ink)
}
