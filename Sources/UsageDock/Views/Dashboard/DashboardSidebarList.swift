import AppKit
import SwiftUI

/// The Dashboard's section list. A click answers in two steps: the rows and
/// the selection capsule change at once, and the page is built a run-loop
/// turn later.
///
/// Kept apart from `DashboardView` so that a click redraws only this list.
/// `DashboardView` rebuilds the page whenever it updates, so holding the
/// pending click there would build the page twice.
struct DashboardSidebarList: View {
    @ObservedObject var navigator: DashboardNavigator
    /// Windows projected to run out before reset, badged on the Limits row.
    let limitsAttention: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The section just clicked, while its page has not been built yet. The
    /// rows and the capsule follow it; it clears once the navigator catches up.
    @State private var pending: DashboardSection?
    @State private var clicks = SidebarClickLedger()

    /// Every row is the same height whatever its icon or trailing count, and
    /// every icon sits in the same fixed column, so all labels start on one line.
    static let rowHeight: CGFloat = 28
    static let iconWidth: CGFloat = 18

    private var shown: DashboardSection { pending ?? navigator.selection }

    var body: some View {
        // Custom nav list: SwiftUI `.tint` does not recolor the macOS
        // NSTableView sidebar selection (it follows the system accent), so
        // selection is rendered here as an explicit violet capsule to stay
        // on the pixel-tech brand.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(DashboardSection.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 3)
                        ForEach(DashboardSection.sections(in: group)) { section in
                            row(section)
                        }
                    }
                }
            }
            .backgroundPreferenceValue(SidebarRowBoundsKey.self) { rows in
                // Geometry only flows down into a layer that takes no part in
                // layout; nothing measured is written back.
                GeometryReader { proxy in
                    SidebarSelectionCapsule(
                        selection: shown,
                        rect: rows[shown].map { proxy[$0] },
                        containerHeight: proxy.size.height,
                        color: NSColor(DashboardTheme.violet).cgColor,
                        animates: !reduceMotion
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onChange(of: navigator.selection) { _, selection in
            // Settled: the page caught up with the last click, or it was
            // changed from elsewhere (the menu-bar popup, an alert) with no
            // click still on its way.
            if pending == selection || clicks.latest == nil { pending = nil }
        }
    }

    private func row(_ section: DashboardSection) -> some View {
        let isSelected = shown == section
        let count = section == .limits ? limitsAttention : 0
        return Button {
            select(section)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .frame(width: Self.iconWidth, alignment: .center)
                    .accessibilityHidden(true)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    attentionBadge(count, onSelection: isSelected)
                }
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : DashboardTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        // No SwiftUI press ripple or spring here: each SwiftUI animation
        // frame makes AppKit recompute the window's drag region, which walks
        // the whole SwiftUI focus tree (~0.6 s of busy frames per click,
        // issue #102). The capsule moves in Core Animation instead.
        .buttonStyle(.plain)
        .anchorPreference(key: SidebarRowBoundsKey.self, value: .bounds) { [section: $0] }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(count > 0 ? "\(count) · \(L10n.text("pace.ahead_warning"))" : "")
    }

    /// How many windows are projected to run out before reset — the queue
    /// the Limits page exists for. Hidden at zero.
    private func attentionBadge(_ count: Int, onSelection: Bool) -> some View {
        Text("\(count)")
            .numericFont(11, .bold)
            .foregroundStyle(onSelection ? Color.white : DashboardTheme.warning)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                Capsule().fill(onSelection ? Color.white.opacity(0.22) : DashboardTheme.warning.opacity(0.16))
            )
            .help(L10n.text("pace.ahead_warning"))
    }

    private func select(_ section: DashboardSection) {
        // Re-publishing the current page would rebuild it for nothing.
        guard section != shown else { return }
        pending = section
        clicks.latest = section
        // The page is built on a later turn, so the rows and the capsule
        // answer this click on screen first. A main-queue block would run
        // before this turn's display cycle and land in the same commit as the
        // page; a run-loop timer only fires after the loop has committed.
        let navigator = navigator
        let clicks = clicks
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                // A newer click supersedes this one.
                guard clicks.latest == section else { return }
                clicks.latest = nil
                if navigator.selection != section { navigator.selection = section }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// The last click whose page is still to be built. A plain class in
/// `@State`: the timer reads it after the click's view update has passed.
@MainActor
private final class SidebarClickLedger {
    var latest: DashboardSection?
}

private struct SidebarRowBoundsKey: PreferenceKey {
    static let defaultValue: [DashboardSection: Anchor<CGRect>] = [:]

    static func reduce(value: inout [DashboardSection: Anchor<CGRect>], nextValue: () -> [DashboardSection: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The violet selection capsule as one Core Animation layer. It slides from
/// the old row to the new one in the render server, so the app draws no
/// frames for it, and it keeps moving while the main thread builds the page.
private struct SidebarSelectionCapsule: NSViewRepresentable {
    let selection: DashboardSection
    let rect: CGRect?
    let containerHeight: CGFloat
    let color: CGColor
    let animates: Bool

    func makeNSView(context: Context) -> SidebarSelectionCapsuleView {
        SidebarSelectionCapsuleView()
    }

    func updateNSView(_ view: SidebarSelectionCapsuleView, context: Context) {
        view.update(selection: selection, rect: rect, containerHeight: containerHeight, color: color, animates: animates)
    }
}

private final class SidebarSelectionCapsuleView: NSView {
    private static let slideKey = "slide"
    private let capsule = CALayer()
    private var placedSelection: DashboardSection?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        capsule.cornerRadius = 7
        capsule.cornerCurve = .continuous
        capsule.isHidden = true
        layer?.addSublayer(capsule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(selection: DashboardSection, rect: CGRect?, containerHeight: CGFloat, color: CGColor, animates: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        capsule.backgroundColor = color
        guard let rect, rect.width > 0, rect.height > 0 else {
            capsule.isHidden = true
            return
        }
        // Only a new selection slides. The same selection at a new place
        // (window resize, rows reflowing) just moves there.
        let slides = animates && !capsule.isHidden && placedSelection != nil && placedSelection != selection
        placedSelection = selection
        // Start from where the capsule is on screen, so a click during a
        // slide continues smoothly instead of jumping back.
        let from = capsule.presentation()?.position ?? capsule.position
        capsule.bounds = CGRect(origin: .zero, size: rect.size)
        // The layer is unflipped: y runs up from the bottom of the list.
        capsule.position = CGPoint(x: rect.midX, y: containerHeight - rect.midY)
        capsule.isHidden = false
        guard slides else {
            capsule.removeAnimation(forKey: Self.slideKey)
            return
        }
        let slide = CASpringAnimation(
            perceptualDuration: MotionTiming.sidebarSlide,
            bounce: MotionTiming.sidebarSlideBounce
        )
        slide.keyPath = "position"
        slide.fromValue = NSValue(point: from)
        slide.toValue = NSValue(point: capsule.position)
        slide.duration = slide.settlingDuration
        capsule.add(slide, forKey: Self.slideKey)
    }
}
