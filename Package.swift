// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.executable(name: "claude-meter", targets: ["ClaudeMeterCLI"])]
var targets: [Target] = [
    .target(name: "MeterCore"),
    .executableTarget(name: "ClaudeMeterCLI", dependencies: ["MeterCore"]),
    .testTarget(name: "MeterCoreTests", dependencies: ["MeterCore"]),
]

// The menu bar app needs AppKit; on Linux only the core and the command build.
#if os(macOS)
products.append(.executable(name: "ClaudeMeter", targets: ["ClaudeMeter"]))
targets.append(.executableTarget(name: "ClaudeMeter", dependencies: ["MeterCore"]))
#endif

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
