// swift-tools-version: 6.1
// Vendored from a fork of acumen-dev/hap-swift (Apache-2.0); see NOTICE.
import PackageDescription

let package = Package(
    name: "HAPSwift",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "HAPApple", targets: ["HAPApple"]),
        .library(name: "HAPTransport", targets: ["HAPTransport"]),
        .library(name: "HAPCrypto", targets: ["HAPCrypto"]),
        .library(name: "HAPCore", targets: ["HAPCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/acumen-dev/mdns-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "HAPCore", dependencies: [.product(name: "Logging", package: "swift-log")]),
        .target(name: "HAPCrypto", dependencies: [
            "HAPCore",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .target(name: "HAPTransport", dependencies: [
            "HAPCore", "HAPCrypto",
            .product(name: "MDNSCore", package: "mdns-swift"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "HAPApple", dependencies: [
            "HAPTransport",
            .product(name: "MDNSApple", package: "mdns-swift"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .testTarget(name: "HAPCoreTests", dependencies: ["HAPCore"]),
        .testTarget(name: "HAPCryptoTests", dependencies: ["HAPCrypto"]),
        .testTarget(name: "HAPTransportTests", dependencies: ["HAPTransport"]),
        .testTarget(name: "HAPAppleTests", dependencies: [
            "HAPApple", "HAPCrypto", "HAPCore", "HAPTransport", .product(name: "MDNSCore", package: "mdns-swift"),
        ]),
    ]
)
