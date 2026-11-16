// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SettleInCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SettleInCore", targets: ["SettleInCore"])
    ],
    targets: [
        .target(name: "SettleInCore"),
        .testTarget(name: "SettleInCoreTests", dependencies: ["SettleInCore"])
    ]
)
