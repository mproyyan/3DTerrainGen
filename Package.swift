// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TerrainCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "TerrainCore", targets: ["TerrainCore"])],
    dependencies: [
        .package(url: "https://github.com/ngageoint/coordinate-reference-systems-ios.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "TerrainCore",
            dependencies: [
                .product(name: "CoordinateReferenceSystems", package: "coordinate-reference-systems-ios")
            ],
            path: "Demnas3DMap/Core",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(name: "TerrainCoreTests", dependencies: ["TerrainCore"], path: "Tests/TerrainCoreTests")
    ]
)
