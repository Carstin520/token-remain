import AppKit

/// Whether one of TokenRemain's primary surfaces exists yet, and if so whether
/// the user can actually see it.
///
/// "Not created" is spelled out as its own case on purpose. Background refresh
/// asks about visibility on a timer, long before the user has opened anything,
/// and the honest answer for a surface that does not exist is *not* "invisible"
/// — it is "there is nothing to ask". Collapsing the two is what shipped the
/// crash in 1.3.0-1.3.4: `menuBarPopupIsShown` read `isShown` off a `lazy var`,
/// so merely *asking* whether the popup was visible built the whole Liquid
/// Glass window, which then resized itself to death. See
/// [FixedHostingWindowSizing] and `script/verify_launch_surface_isolation.sh`.
enum SurfaceState: Equatable {
    case notCreated
    case created(visible: Bool)

    /// Only a surface that exists *and* is on screen counts. A `.notCreated`
    /// surface can never answer yes, which is the whole point of the type.
    var countsAsVisible: Bool {
        self == .created(visible: true)
    }

    /// Reads visibility from a window that may not have been built yet.
    ///
    /// `NSWindow.isVisible` stays true while another app fully covers the
    /// window, so occlusion is the useful energy signal: a covered or
    /// minimized surface cannot benefit from minute-level background work.
    static func forWindow(_ window: @autoclosure () -> NSWindow?, created: Bool) -> SurfaceState {
        guard created, let window = window() else { return .notCreated }
        return .created(
            visible: window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        )
    }
}

/// Are local usage and the AI Feed currently on screen anywhere?
///
/// Only while one of these surfaces is visible is it worth sustaining
/// minute-level ccusage scans and Feed polling.
enum PrimarySurfaceVisibility {
    static func isVisible(
        popup: SurfaceState,
        dashboard: SurfaceState,
        floatingWidget: SurfaceState
    ) -> Bool {
        popup.countsAsVisible
            || dashboard.countsAsVisible
            || floatingWidget.countsAsVisible
    }
}
