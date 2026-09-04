// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitBridgeKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GitBridgeKit",
            targets: ["GitBridgeKit"]
        )
    ],
    targets: [
        .target(
            name: "GitBridgeKit",
            dependencies: []
        ),
        .testTarget(
            name: "GitBridgeKitTests",
            dependencies: ["GitBridgeKit"]
        )
    ]
)
