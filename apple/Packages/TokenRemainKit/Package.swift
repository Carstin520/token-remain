// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenRemainKit",
    // English is the neutral base localization; zh-Hans is the second. These exist
    // only so `Bundle.module.preferredLocalizations` reports both languages, letting
    // `TRL10n.resolve` follow the system language (see TRL10n.swift). The actual
    // strings live in the pure-Swift `TRL10n` table.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        // macOS is not a shipping surface; it exists so `swift test` can run the
        // pure-logic suite without booting a simulator.
        .macOS(.v14)
    ],
    products: [
        .library(name: "TokenRemainKit", targets: ["TokenRemainKit"])
    ],
    targets: [
        .target(
            name: "TokenRemainKit",
            resources: [
                // The Claude identity mark is the vendor's bundled starburst artwork,
                // copied from the desktop package and rendered as a template image so
                // it can be tinted coral (palette.md rule 0).
                .process("Resources/Media.xcassets")
            ]
        ),
        .testTarget(name: "TokenRemainKitTests", dependencies: ["TokenRemainKit"])
    ]
)
