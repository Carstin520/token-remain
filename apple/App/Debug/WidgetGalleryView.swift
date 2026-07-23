import SwiftUI
import TokenRemainKit
import WidgetKit

/// A screenshot-only gallery that renders the **real** widget entry views
/// (`TRHeroView`, `TRProvidersView`, the Lock Screen accessories) at their true
/// WidgetKit point sizes on the ink canvas. It exists purely so the composed
/// widgets can be captured deterministically in the simulator — WidgetKit's own
/// gallery / Home-Screen placement is not `simctl`-scriptable. Gated behind the
/// `-tr-widget-gallery` launch argument and never reachable in normal use.
///
/// The `Widgets/TRWidgetViews.swift` file is compiled into the app target as well
/// as the extension, so these are the exact shipping views, not reconstructions.
/// Pass `-tr-family <name>` to render a single family centred at true size (for
/// individual, crop-friendly captures); otherwise the whole set is listed.
struct WidgetGalleryView: View {
    let entry: TREntry
    /// nil → full list; otherwise one of the family identifiers below.
    var family: String?

    // Canonical WidgetKit dimensions (iPhone 17 Pro class).
    private let small = CGSize(width: 170, height: 170)
    private let medium = CGSize(width: 364, height: 170)
    private let accessory = CGFloat(76)
    private let rectangular = CGSize(width: 172, height: 76)

    var body: some View {
        Group {
            if let family {
                single(family)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fullList
            }
        }
        .background(TRTheme.ink)
    }

    /// One family, centred at true size — the frame the capture script crops to.
    @ViewBuilder
    private func single(_ family: String) -> some View {
        switch family {
        case "home-small":
            homeTile(small) { TRHeroView(entry: entry) }
        case "home-medium":
            homeTile(medium) { TRProvidersView(entry: entry) }
        case "lock-circular":
            circle { TRCircularView(entry: entry) }
        case "lock-rectangular":
            tile(rectangular) { TRRectangularView(entry: entry) }
        case "lock-inline":
            TRInlineView(entry: entry)
                .foregroundStyle(TRTheme.text)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(TRTheme.ink, in: Capsule())
                .overlay { Capsule().strokeBorder(TRTheme.border, lineWidth: 1) }
                .fixedSize()
        default:
            Text("unknown family: \(family)")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(TRTheme.textDim)
        }
    }

    private var fullList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                label("Home · Small")
                homeTile(small) { TRHeroView(entry: entry) }

                label("Home · Medium")
                homeTile(medium) { TRProvidersView(entry: entry) }

                label("Lock · Circular (double ring)")
                HStack(spacing: 18) {
                    circle { TRCircularView(entry: entry) }
                    circle { TRResetCircularView(entry: entry) }
                }

                label("Lock · Rectangular")
                tile(rectangular) { TRRectangularView(entry: entry) }

                label("Lock · Inline")
                tile(CGSize(width: rectangular.width, height: 28)) { TRInlineView(entry: entry) }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(TRTheme.textDim)
    }

    /// The shipping Home widgets disable WidgetKit's default content margins and
    /// own their full-bleed card inset, so the gallery must not add a second one.
    private func homeTile<Content: View>(_ size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
    }

    private func tile<Content: View>(_ size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(8)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(TRTheme.ink)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(TRTheme.border, lineWidth: 1)
            }
    }

    private func circle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: accessory, height: accessory)
            .background(TRTheme.ink, in: Circle())
            .overlay { Circle().strokeBorder(TRTheme.border, lineWidth: 1) }
    }
}
