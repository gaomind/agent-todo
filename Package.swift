// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHold",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentHold", targets: ["AgentHold"]),
        .executable(name: "AgentHoldHook", targets: ["AgentHoldHook"]),
    ],
    targets: [
        .target(name: "AgentHoldCaptureSupport"),
        .executableTarget(name: "AgentHold", dependencies: ["AgentHoldCaptureSupport"]),
        .executableTarget(name: "AgentHoldHook", dependencies: ["AgentHoldCaptureSupport"]),
        .testTarget(name: "AgentHoldTests", dependencies: ["AgentHold"]),
    ]
)
