// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Apple2Forge",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Apple2ForgeCore"),
        .executableTarget(name: "Apple2Forge", dependencies: ["Apple2ForgeCore"]),
        .testTarget(name: "Apple2ForgeCoreTests", dependencies: ["Apple2ForgeCore"]),
    ]
)
