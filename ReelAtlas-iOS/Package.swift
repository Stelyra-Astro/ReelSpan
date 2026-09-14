// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReelAtlasCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ReelAtlasCore", targets: ["ReelAtlasCore"])],
    targets: [
        .target(name: "ReelAtlasCore", path: "ReelAtlas/Core"),
        .testTarget(name: "ReelAtlasCoreTests", dependencies: ["ReelAtlasCore"], path: "Tests/ReelAtlasCoreTests")
    ]
)
