// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalCoreKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TerminalCoreKit",
            targets: ["TerminalCoreKit"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TerminalCoreKit",
            dependencies: [],
            path: "Sources/TerminalCoreKit"
        ),
        .testTarget(
            name: "TerminalCoreKitTests",
            dependencies: ["TerminalCoreKit"],
            path: "Tests/TerminalCoreKitTests"
        ),
    ]
)
