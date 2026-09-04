// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAppServerKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CodexAppServerKit",
            targets: ["CodexAppServerKit"]
        ),
    ],
    targets: [
        .target(
            name: "CodexAppServerKit",
            path: "Sources/CodexAppServerKit"
        ),
        .testTarget(
            name: "CodexAppServerKitTests",
            dependencies: ["CodexAppServerKit"],
            path: "Tests/CodexAppServerKitTests"
        ),
    ]
)
