// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LSPClientKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LSPClientKit",
            targets: ["LSPClientKit"]
        )
    ],
    targets: [
        .target(
            name: "LSPClientKit",
            dependencies: []
        ),
        .testTarget(
            name: "LSPClientKitTests",
            dependencies: ["LSPClientKit"]
        )
    ]
)
