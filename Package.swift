// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "tx3-swift-sdk",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "Tx3SDK", targets: ["Tx3SDK"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/attaswift/BigInt.git",
            exact: "5.7.0"
        ),
        .package(
            url: "https://github.com/Kingpin-Apps/swift-nacl.git",
            exact: "1.0.2"
        ),
    ],
    targets: [
        .target(
            name: "Tx3SDK",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "SwiftNaCl", package: "swift-nacl"),
            ],
            resources: [.copy("Resources/bip39-english.txt")]
        ),
        .testTarget(
            name: "Tx3SDKTests",
            dependencies: ["Tx3SDK"],
            resources: [.copy("Fixtures/signer-vectors.json")]
        ),
        .testTarget(
            name: "Tx3SDKE2ETests",
            dependencies: ["Tx3SDK"]
        ),
    ]
)
