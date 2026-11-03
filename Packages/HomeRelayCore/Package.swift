// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeRelayCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "HomeRelayCore", targets: ["HomeRelayCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "HomeRelayCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "HomeRelayCoreTests",
            dependencies: ["HomeRelayCore", .product(name: "NIOCore", package: "swift-nio")]
        ),
    ]
)
