// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MonitorKeys",
    platforms: [.macOS(.v14)],
    targets: [
        // Logic testable without the app: the brightness ramp, the MCCS packet codec, the schedule,
        // and the check that the app's code on disk is unchanged (file and code-signature reads).
        // No hardware access.
        .target(name: "MonitorKeysCore"),
        // The menu-bar app: display discovery, channels, UI.
        .executableTarget(name: "MonitorKeys", dependencies: ["MonitorKeysCore"]),
        .testTarget(name: "MonitorKeysCoreTests", dependencies: ["MonitorKeysCore"]),
    ],
    swiftLanguageModes: [.v5]
)
