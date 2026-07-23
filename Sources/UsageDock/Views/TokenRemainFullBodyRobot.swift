import AppKit
import SwiftUI

/// The selected concept-10 full-body pet used on roomy app surfaces.
/// Four deliberately stepped poses create a small pixel-style idle bounce.
struct TokenRemainFullBodyRobot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let remainingPercent: Double?
    let size: CGFloat
    var animated = true

    private var state: TokenRemainLogoState {
        .resolve(remainingPercent: remainingPercent)
    }

    var body: some View {
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
        .accessibilityLabel(L10n.format("logo.accessibility.brand_state", state.accessibilityDescription))
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = TokenRemainFullBodyArtwork.image(for: state) {
            Image(nsImage: image)
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
}

private enum TokenRemainFullBodyArtwork {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for state: TokenRemainLogoState) -> NSImage? {
        let key = state.rawValue as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = AppResourceBundle.bundle.url(
            forResource: "fullbody-\(state.rawValue)",
            withExtension: "png",
            subdirectory: "TokenRemainFullBodyStates"
        ), let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
