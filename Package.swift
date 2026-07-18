// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageDock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageDock", targets: ["UsageDock"])
    ],
    targets: [
        .executableTarget(
            name: "UsageDock",
            path: "Sources/UsageDock",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "UsageDockTests",
            dependencies: ["UsageDock"]
        )
    ]
)
