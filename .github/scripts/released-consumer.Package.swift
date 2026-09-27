// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ReleasedConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/tx3-lang/swift-sdk", exact: "__VERSION__")
    ],
    targets: [
        .executableTarget(
            name: "ReleasedConsumer",
            dependencies: [.product(name: "Tx3SDK", package: "swift-sdk")]
        )
    ]
)
