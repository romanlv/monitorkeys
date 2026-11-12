// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MonitorKeys",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: the brightness ramp and the MCCS packet codec. No hardware access.
        .target(name: "MonitorKeysCore"),
        // The menu-bar app: display discovery, channels, UI.
        .executableTarget(name: "MonitorKeys", dependencies: ["MonitorKeysCore"]),
        .testTarget(name: "MonitorKeysCoreTests", dependencies: ["MonitorKeysCore"]),
    ],
    swiftLanguageModes: [.v5]
)
