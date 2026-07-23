// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenRemainKit",
    // English is the neutral base localization. Marker resources for every supported
    // language let `Bundle.module.preferredLocalizations` follow the user's system or
    // per-app language choice, while the actual copy remains in the pure-Swift table.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        // macOS is not a shipping surface; it exists so `swift test` can run the
        // pure-logic suite without booting a simulator.
        .macOS(.v14)
    ],
    products: [
        .library(name: "TokenRemainKit", targets: ["TokenRemainKit"]),
        // Resource-free cross-device protocol. The macOS app can depend on this
        // product without importing iPhone UI models or asset catalogs.
        .library(name: "TokenRemainSyncKit", targets: ["TokenRemainSyncKit"])
    ],
    targets: [
        .target(name: "TokenRemainSyncKit"),
        .target(
            name: "TokenRemainKit",
            resources: [
                // The Claude identity mark is the vendor's bundled starburst artwork,
                // copied from the desktop package and rendered as a template image so
                // it can be tinted coral (palette.md rule 0).
                .process("Resources/Media.xcassets"),
                // Head-only 3D pixel-pet expressions. Provider meters remain
                // code-drawn so live quota changes do not require new artwork.
                .process("Resources/HeadLogoStates"),
                // Full-body expressions are reserved for the app's overview
                // hero; widgets continue to use the compact head-only mark.
                .process("Resources/FullBodyLogoStates")
            ]
        ),
        .testTarget(name: "TokenRemainKitTests", dependencies: ["TokenRemainKit"]),
        .testTarget(name: "TokenRemainSyncKitTests", dependencies: ["TokenRemainSyncKit"])
    ]
)
