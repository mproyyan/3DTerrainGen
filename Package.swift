// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TerrainCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "TerrainCore", targets: ["TerrainCore"])],
    targets: [
        .target(name: "TerrainCore", path: "Demnas3DMap/Core", linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "TerrainCoreTests", dependencies: ["TerrainCore"], path: "Tests/TerrainCoreTests")
    ]
)
