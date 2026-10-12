// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GlassStroke",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GlassStroke", targets: ["GlassStroke"]),
        .executable(name: "glassstroke", targets: ["glassstroke"]),
    ],
    targets: [
        .target(name: "GlassStroke"),
        .executableTarget(name: "glassstroke", dependencies: ["GlassStroke"], path: "Sources/CLI"),
    ]
)
