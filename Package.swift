// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenRemain",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageDock", targets: ["UsageDock"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        .package(path: "apple/Packages/TokenRemainKit")
    ],
    targets: [
        .executableTarget(
            name: "UsageDock",
            dependencies: [
                .product(name: "TokenRemainSyncKit", package: "TokenRemainKit"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/UsageDock",
            exclude: ["Resources", "Localization"],
            linkerSettings: [
                // SwiftPM runs the executable beside Sparkle.framework during
                // development. The packaged app embeds it one directory above
                // the executable in Contents/Frameworks.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "UsageDockTests",
            dependencies: ["UsageDock"]
        )
    ]
)
