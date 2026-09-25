// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "tx3-swift-sdk",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "Tx3SDK", targets: ["Tx3SDK"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/attaswift/BigInt.git",
            exact: "6.0.1"
        )
    ],
    targets: [
        .target(
            name: "Tx3SDK",
            dependencies: [
                .product(name: "BigInt", package: "BigInt")
            ]
        ),
        .testTarget(
            name: "Tx3SDKTests",
            dependencies: ["Tx3SDK"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "Tx3SDKE2ETests",
            dependencies: ["Tx3SDK"]
        ),
    ]
)
