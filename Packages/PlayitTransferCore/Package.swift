// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlayitTransferCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PlayitTransferCore", targets: ["PlayitTransferCore"])],
    targets: [
        .target(name: "PlayitTransferCore"),
        .testTarget(name: "PlayitTransferCoreTests", dependencies: ["PlayitTransferCore"])
    ]
)
