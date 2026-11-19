// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlayitCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PlayitCore", targets: ["PlayitCore"])],
    targets: [
        .target(name: "PlayitCore"),
        .testTarget(name: "PlayitCoreTests", dependencies: ["PlayitCore"])
    ]
)
