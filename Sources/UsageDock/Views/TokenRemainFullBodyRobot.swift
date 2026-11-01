import AppKit
import QuartzCore
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
        Group {
            if let image = TokenRemainFullBodyArtwork.image(for: state) {
                RobotBounceLayerView(image: image, animated: animated && !reduceMotion)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("logo.accessibility.brand_state", state.accessibilityDescription))
    }
}

/// One step of the idle bounce: a lift in points (upward positive) and a
/// squash about the feet.
struct RobotIdlePose: Equatable {
    let lift: CGFloat
    let scaleX: CGFloat
    let scaleY: CGFloat

    static let stepDuration: CFTimeInterval = 0.22
    static let cycle: [RobotIdlePose] = [
        RobotIdlePose(lift: 0, scaleX: 1, scaleY: 1),
        RobotIdlePose(lift: 1, scaleX: 1.004, scaleY: 0.996),
        RobotIdlePose(lift: 1, scaleX: 1.008, scaleY: 0.992),
        RobotIdlePose(lift: 0, scaleX: 1.004, scaleY: 0.996),
    ]

    /// Squash about the layer's bottom-centre anchor, then lift.
    var transform: CATransform3D {
        CATransform3DConcat(
            CATransform3DMakeScale(scaleX, scaleY, 1),
            CATransform3DMakeTranslation(0, lift, 0)
        )
    }
}

/// Plays the bounce as a discrete Core Animation keyframe loop, so the
/// render server steps the poses. Stepping them from a SwiftUI TimelineView
/// updated the view graph ~4.5 times a second, and each update re-laid out
/// the dashboard window: ~8% CPU while it sat idle.
private struct RobotBounceLayerView: NSViewRepresentable {
    let image: NSImage
    let animated: Bool

    func makeNSView(context: Context) -> RobotBounceNSView {
        RobotBounceNSView()
    }

    func updateNSView(_ view: RobotBounceNSView, context: Context) {
        view.update(image: image, animated: animated)
    }
}

private final class RobotBounceNSView: NSView {
    private static let animationKey = "idleBounce"
    private let artwork = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        artwork.contentsGravity = .resizeAspect
        // Pixel art: nearest-neighbour, as `.interpolation(.none)` did.
        artwork.magnificationFilter = .nearest
        artwork.minificationFilter = .nearest
        artwork.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(artwork)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.bounds = bounds
        artwork.position = CGPoint(x: bounds.midX, y: bounds.minY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        artwork.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        artwork.contentsScale = window?.backingScaleFactor ?? 2
    }

    func update(image: NSImage, animated: Bool) {
        if artwork.contents as? NSImage !== image {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            artwork.contents = image
            CATransaction.commit()
        }
        let running = artwork.animation(forKey: Self.animationKey) != nil
        if animated, !running {
            let poses = RobotIdlePose.cycle
            let bounce = CAKeyframeAnimation(keyPath: "transform")
            bounce.values = poses.map { NSValue(caTransform3D: $0.transform) }
            // Discrete keyframes take one more key time than values.
            bounce.keyTimes = (0...poses.count).map { NSNumber(value: Double($0) / Double(poses.count)) }
            bounce.calculationMode = .discrete
            bounce.duration = RobotIdlePose.stepDuration * Double(poses.count)
            bounce.repeatCount = .infinity
            bounce.isRemovedOnCompletion = false
            artwork.add(bounce, forKey: Self.animationKey)
        } else if !animated, running {
            artwork.removeAnimation(forKey: Self.animationKey)
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
