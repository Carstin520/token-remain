// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenRemain",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageDock", targets: ["UsageDock"])
    ],
    dependencies: [
        .package(path: "apple/Packages/TokenRemainKit")
    ],
    targets: [
        .executableTarget(
            name: "UsageDock",
            dependencies: [
                .product(name: "TokenRemainSyncKit", package: "TokenRemainKit")
            ],
            path: "Sources/UsageDock",
            exclude: ["Resources", "Localization"]
        ),
        .testTarget(
            name: "UsageDockTests",
            dependencies: ["UsageDock"]
        )
    ]
)
