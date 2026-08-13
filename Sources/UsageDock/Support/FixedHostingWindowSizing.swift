import AppKit
import SwiftUI

/// AppKit owns the size of every standalone TokenRemain window. Disable
/// SwiftUI's content-derived Auto Layout constraints so `NSHostingView` cannot
/// resize the containing `NSWindow` again from `windowDidLayout()`.
///
/// This ownership boundary is especially important on macOS 26: feeding a
/// Liquid Glass layout change back into the window frame can synchronously
/// re-enter `NSHostingView.layout()` until the main-thread stack is exhausted.
@MainActor
enum FixedHostingWindowSizing {
    static func configure<Content: View>(_ hosting: NSHostingController<Content>) {
        hosting.sizingOptions = []
    }
}
