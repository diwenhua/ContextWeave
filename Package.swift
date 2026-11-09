// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextWeave",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ContextWeave", targets: ["ContextWeaveApp"]),
        .library(name: "ContextWeaveCore", targets: ["ContextWeaveCore"])
    ],
    targets: [
        .target(name: "ContextWeaveCore"),
        .executableTarget(name: "ContextWeaveApp", dependencies: ["ContextWeaveCore"], resources: [.process("Resources")]),
        .testTarget(name: "ContextWeaveCoreTests", dependencies: ["ContextWeaveCore"])
    ]
)
