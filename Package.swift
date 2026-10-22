// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MeterCore"),
        .executableTarget(name: "ClaudeMeter", dependencies: ["MeterCore"]),
        .testTarget(name: "MeterCoreTests", dependencies: ["MeterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
