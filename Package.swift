// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "loeti-way",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lw", targets: ["LoetiWayCLI"]),
        .library(name: "LoetiWayKit", targets: ["LoetiWayKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "LoetiWayKit",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "LoetiWayCLI",
            dependencies: [
                "LoetiWayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LoetiWayKitTests",
            dependencies: ["LoetiWayKit"]
        ),
    ]
)
