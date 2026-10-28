// swift-tools-version: 6.0

import PackageDescription

// BridgeCore is everything in the Dicavo CLI Bridge below its menu-bar app:
// the loopback server, the request handler, the command runner and the
// updater, on Apple's system frameworks alone. The menu-bar application in Sources/DicavoBridge is built
// by DicavoBridge.xcodeproj, which compiles both directories into one module.
let package = Package(
    name: "DicavoCLIBridge",
    defaultLocalization: "en",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"])
    ],
    targets: [
        .target(
            name: "BridgeCore",
            path: "Sources/BridgeCore"
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"],
            path: "Tests/BridgeCoreTests"
        )
    ]
)
