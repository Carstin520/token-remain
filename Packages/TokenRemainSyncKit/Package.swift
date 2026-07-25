// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenRemainSyncKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenRemainSyncKit", targets: ["TokenRemainSyncKit"])
    ],
    targets: [
        .target(name: "TokenRemainSyncKit"),
        .testTarget(
            name: "TokenRemainSyncKitTests",
            dependencies: ["TokenRemainSyncKit"]
        )
    ]
)
