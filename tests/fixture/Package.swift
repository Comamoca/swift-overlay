// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OverlayFixture",
    targets: [
        .target(name: "FixtureLib"),
        .executableTarget(name: "fixture-cli", dependencies: ["FixtureLib"]),
        .testTarget(name: "FixtureLibTests", dependencies: ["FixtureLib"]),
    ]
)
