// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextWeave",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ContextWeave", targets: ["ContextWeaveApp"]),
        .library(name: "ContextWeaveCore", targets: ["ContextWeaveCore"])
    ],
    targets: [
        .target(name: "ContextWeaveCore"),
        .executableTarget(name: "ContextWeaveApp", dependencies: ["ContextWeaveCore"]),
        .testTarget(name: "ContextWeaveCoreTests", dependencies: ["ContextWeaveCore"])
    ]
)
