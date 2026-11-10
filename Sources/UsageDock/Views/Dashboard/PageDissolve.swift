import AppKit
import SwiftUI

extension View {
    /// Cross-dissolves the detail column from the old page to the new one
    /// whenever `page` changes. Off under Reduce Motion.
    func pageDissolve(on page: DashboardSection) -> some View {
        background {
            PageDissolveProbe(page: page)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A zero-size view that, when the page changes, adds a fade `CATransition`
/// to the layer of the split view's detail column.
///
/// The probe updates in the same view-graph update that builds the new page,
/// so the transition joins the same Core Animation transaction. The render
/// server keeps the last committed page as the "from" image and fades to the
/// new one: the app draws no frames for it. A SwiftUI opacity transition
/// would re-render the whole page every frame, and each of those frames also
/// makes AppKit recompute the window's drag region (issue #102). Where the
/// column cannot be found, pages switch without a fade.
private struct PageDissolveProbe: NSViewRepresentable {
    let page: DashboardSection

    func makeNSView(context: Context) -> PageDissolveProbeView {
        PageDissolveProbeView()
    }

    func updateNSView(_ view: PageDissolveProbeView, context: Context) {
        view.update(page: page, enabled: !context.environment.accessibilityReduceMotion)
    }
}

private final class PageDissolveProbeView: NSView {
    private static let transitionKey = "pageDissolve"
    private var page: DashboardSection?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(page: DashboardSection, enabled: Bool) {
        defer { self.page = page }
        guard enabled, let previous = self.page, previous != page, let column = columnLayer() else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = MotionTiming.pageDissolve
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        column.add(fade, forKey: Self.transitionKey)
    }

    /// The layer of the view that sits directly in the split view: the whole
    /// detail column, page and canvas, without the sidebar.
    private func columnLayer() -> CALayer? {
        var view: NSView = self
        while let parent = view.superview {
            if parent is NSSplitView { return view.layer }
            view = parent
        }
        return nil
    }
}
