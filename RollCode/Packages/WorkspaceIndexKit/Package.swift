// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkspaceIndexKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WorkspaceIndexKit",
            targets: ["WorkspaceIndexKit"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WorkspaceIndexKit",
            dependencies: [],
            path: "Sources/WorkspaceIndexKit"
        ),
        .testTarget(
            name: "WorkspaceIndexKitTests",
            dependencies: ["WorkspaceIndexKit"],
            path: "Tests/WorkspaceIndexKitTests"
        ),
    ]
)
