// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextWeave",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ContextWeave", targets: ["ContextWeaveApp"]),
        .library(name: "ContextWeaveCore", targets: ["ContextWeaveCore"]),
        .executable(name: "contextweave-mcp", targets: ["ContextWeaveMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ContextWeaveCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ContextWeaveMCP", dependencies: ["ContextWeaveCore"]),
        .executableTarget(name: "ContextWeaveApp", dependencies: ["ContextWeaveCore", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ContextWeaveCoreTests", dependencies: ["ContextWeaveCore"])
    ]
)
