import AppKit
import SwiftUI

struct BrandIcon: View {
    let provider: ProviderQuota.Provider

    var body: some View {
        Image(nsImage: Self.image(for: provider))
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .accessibilityLabel(provider.rawValue)
    }

    static func image(for provider: ProviderQuota.Provider) -> NSImage {
        let name = provider == .claude ? "claude" : "openai"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: provider.rawValue)!
        }
        image.isTemplate = true
        return image
    }
}
