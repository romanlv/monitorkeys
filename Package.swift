// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: the lumen ramp and the MCCS packet codec. No hardware access.
        .target(name: "LumenCore"),
        // The menu-bar app: display discovery, channels, UI.
        .executableTarget(name: "Lumen", dependencies: ["LumenCore"]),
        .testTarget(name: "LumenCoreTests", dependencies: ["LumenCore"]),
    ],
    swiftLanguageModes: [.v5]
)
