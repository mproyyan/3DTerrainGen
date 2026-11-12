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
        .testTarget(name: "TerrainCoreTests", dependencies: ["TerrainCore"], path: "Tests/TerrainCoreTests", resources: [.copy("V42PythonReference.json"), .copy("V42PythonReference1m.json"), .copy("V45FeatureManifest.json"), .copy("V45PythonFeatures.json"), .copy("V45FullCandidateParity.json"), .copy("UncertaintyV2PythonParity.json"), .copy("ParitySamples.json"), .copy("DQN_V4_6_A_parity.json"), .copy("V46PythonFeatures.json"), .copy("CoverageV1Parity.json"), .copy("GateV21PythonParity.json")])
    ]
)
