// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Tx3SDKConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "tx3-swift-sdk", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "Tx3SDKConsumer",
            dependencies: [.product(name: "Tx3SDK", package: "tx3-swift-sdk")]
        ),
    ]
)
