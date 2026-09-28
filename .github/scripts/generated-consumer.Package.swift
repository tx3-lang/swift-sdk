// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "GeneratedConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/tx3-lang/swift-sdk.git", from: "0.15.0"),
        .package(name: "UnknownClient", path: "__GENERATED__"),
    ],
    targets: [
        .executableTarget(
            name: "GeneratedConsumer",
            dependencies: [
                .product(name: "Tx3SDK", package: "swift-sdk"),
                .product(name: "UnknownClient", package: "UnknownClient"),
            ]
        )
    ]
)
