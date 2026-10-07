// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RailwayNative", platforms: [.macOS(.v14)], products: [
    .executable(name: "RailwayNative", targets: ["RailwayDesktop"])
], targets: [
    .target(name: "RailwayCore"),
        .target(name: "TerminalProcess"),
    .executableTarget(name: "RailwayDesktop", dependencies: ["RailwayCore", "TerminalProcess"]),
    .testTarget(name: "RailwayCoreTests", dependencies: ["RailwayCore", "TerminalProcess"]),
    .testTarget(name: "RailwayDesktopTests", dependencies: ["RailwayDesktop"])
])
