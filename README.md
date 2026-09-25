# Tx3 Swift SDK

`Tx3SDK` is the Swift package for loading Tx3 protocol interfaces and building,
resolving, signing, and submitting transactions. The package currently provides
the shared public contract types on which those capabilities will be built.

The initial release line is `0.15.x`. It supports macOS 14 or newer and iOS 18
or newer with Swift 6.1 and Swift Package Manager.

## Installation

Add the package in `Package.swift` and depend on the `Tx3SDK` product:

```swift
.package(url: "https://github.com/tx3-lang/swift-sdk.git", from: "0.15.0")
```

```swift
.target(name: "MyApp", dependencies: [.product(name: "Tx3SDK", package: "swift-sdk")])
```

Then import the public module:

```swift
import Tx3SDK
```

Runtime protocol loading and transaction lifecycle APIs are intentionally not
part of this foundation revision. An unavailable operation is never represented
as a successful result.

## Development

Use Xcode 16.4 / Swift 6.1. From the repository root, run:

```console
swift package resolve
swift build --configuration debug
swift format lint --strict --recursive Sources Tests
swift test --filter Tx3SDKTests --parallel
```

The separately selectable `Tx3SDKE2ETests` target is reserved for tests that use
a live TRP endpoint; unit tests never require credentials.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
