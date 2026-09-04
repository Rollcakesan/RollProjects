// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIAgentKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AIAgentKit",
            targets: ["AIAgentKit"]
        ),
    ],
    dependencies: [
        .package(path: "../GitBridgeKit")
    ],
    targets: [
        .target(
            name: "AIAgentKit",
            dependencies: [
                .product(name: "GitBridgeKit", package: "GitBridgeKit")
            ],
            path: "Sources/AIAgentKit"
        ),
        .testTarget(
            name: "AIAgentKitTests",
            dependencies: ["AIAgentKit"],
            path: "Tests/AIAgentKitTests"
        ),
    ]
)
