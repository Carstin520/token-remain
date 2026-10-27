import AppKit
import SwiftUI

/// Calm O4-C head. Only the dot count follows the lowest selected quota.
struct TokenRemainHeadLogo: View {
    let claudeRemaining: Double?
    let codexRemaining: Double?

    var body: some View {
        Image(nsImage: TokenRemainHeadLogoArtwork.image(
            claudeRemaining: claudeRemaining, codexRemaining: codexRemaining, size: 256
        ))
        .resizable()
        .scaledToFit()
        .accessibilityLabel(TokenRemainHeadLogoArtwork.accessibilityLabel(slots:
            TokenRemainHeadLogoArtwork.slots(claudeRemaining: claudeRemaining, codexRemaining: codexRemaining)))
    }
}

enum TokenRemainHeadLogoArtwork {
    struct Slot: Equatable {
        let provider: ProviderQuota.Provider
        let remainingPercent: Double?
    }
    enum Style: String { case bare, dockTile }
    typealias Variant = DotRingIconArtwork.Variant
    static let dockTileFill = DotRingIconArtwork.tileFill
    static let dockTileInset = DotRingIconArtwork.tileInset
    static let dockTileCornerRadius = DotRingIconArtwork.tileCornerRadius
    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 12
        return cache
    }()

    static func slots(claudeRemaining: Double?, codexRemaining: Double?) -> [Slot] {
        [Slot(provider: .claude, remainingPercent: claudeRemaining),
         Slot(provider: .codex, remainingPercent: codexRemaining)]
    }

    /// Keep the existing selected-provider minimum and missing-reading semantics.
    static func moodRemaining(_ slots: [Slot]) -> Double? {
        slots.compactMap(\.remainingPercent).min()
    }

    static func litCount(remainingPercent: Double?, variant: Variant = .full) -> Int {
        DotRingIconArtwork.litCount(remainingPercent: remainingPercent, variant: variant)
    }

    static func renderKey(claudeRemaining: Double?, codexRemaining: Double?) -> String {
        renderKey(slots: slots(claudeRemaining: claudeRemaining, codexRemaining: codexRemaining))
    }

    /// Provider identity/order cannot change a uniform ring. Missing data stays
    /// a distinct state even though its zero-lit image matches an exhausted ring.
    static func renderKey(slots: [Slot], variant: Variant = .full) -> String {
        let remaining = moodRemaining(slots)
        return "dot-ring-\(variant.rawValue)-\(remaining == nil ? "missing" : "known")-\(litCount(remainingPercent: remaining, variant: variant))"
    }

    static func accessibilityLabel(slots: [Slot]) -> String {
        let values = slots.compactMap { slot in
            slot.remainingPercent.map { "\(slot.provider.displayName) \(UsageFormatting.percent($0))" }
        }
        return (["TokenRemain"] + values).joined(separator: L10n.text("common.list_separator"))
    }

    static func image(claudeRemaining: Double?, codexRemaining: Double?, size: CGFloat = 1024) -> NSImage {
        image(slots: slots(claudeRemaining: claudeRemaining, codexRemaining: codexRemaining), size: size)
    }

    static func image(slots: [Slot], size: CGFloat = 1024, style: Style = .bare) -> NSImage {
        let pixelSize = max(1, Int(size.rounded()))
        let variant = Variant.resolve(pixelSize: CGFloat(pixelSize))
        let key = "\(renderKey(slots: slots, variant: variant))-\(style.rawValue)-\(pixelSize)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let bitmap = DotRingIconArtwork.cgImage(size: pixelSize, variant: variant,
            litCount: litCount(remainingPercent: moodRemaining(slots), variant: variant),
            style: style == .dockTile ? .dockTile : .bare)
        let image = NSImage(cgImage: bitmap, size: NSSize(width: size, height: size))
        image.isTemplate = false
        imageCache.setObject(image, forKey: key)
        return image
    }
}
