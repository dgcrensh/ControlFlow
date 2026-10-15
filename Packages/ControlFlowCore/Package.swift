// swift-tools-version: 6.0
import PackageDescription

// ControlFlowCore is the UI-free geometry and input core shared by the app.
// It builds and tests on macOS and Linux with `swift test`.
let package = Package(
    name: "ControlFlowCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ControlFlowCore", targets: ["ControlFlowCore"]),
    ],
    targets: [
        .target(name: "ControlFlowCore"),
        .testTarget(name: "ControlFlowCoreTests", dependencies: ["ControlFlowCore"]),
    ]
)
