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

## Load a protocol

Load a canonical `.tii` document from a file URL, JSON bytes, a string, or an
already parsed `JSONValue`:

```swift
let protocolValue = try Protocol.fromFile(tiiURL)
let transfer = protocolValue.transactions["transfer"]

for (name, type) in transfer?.parameters ?? [:] {
    print("\(name): \(type)")
}
```

`Protocol` retains the raw TIR envelopes and JSON schemas while exposing the
interpreted recursive `ParamType` model. Unsupported schema nodes remain
available through `ParamType.unknown` instead of being guessed or rejected.
`Protocol.client()` is the single bridge into the dynamic client-builder flow;
facade configuration and transaction lifecycle APIs arrive in later revisions.

## Low-level TRP client

Advanced consumers can call the Transaction Resolver Protocol directly. Configure
the endpoint and any hosted-service headers once, then use the async client:

```swift
let client = TRPClient(
    options: ClientOptions(
        endpoint: URL(string: "https://trp.example/rpc")!,
        headers: ["Authorization": "Bearer …"],
        timeout: .seconds(30)
    )
)

let resolved = try await client.resolve(
    ResolveParams(
        tir: TIREnvelope(encoding: .hex, content: tirHex, version: "v1"),
        args: ["quantity": .integer(100)]
    )
)
let submitted = try await client.submit(
    SubmitParams(tx: signedTransaction, witnesses: witnesses)
)
let status = try await client.checkStatus([submitted.hash])
```

TRP operations throw `Tx3Error.transport`. Its cases distinguish network, HTTP,
JSON-RPC, malformed-response, timeout, and cancellation failures without string
matching. Custom transports can be injected with
`TRPClient(options:transport:)` for deterministic tests or alternate HTTP stacks.

Higher-level transaction facade APIs are intentionally not part of this revision.
An unavailable operation is never represented as a successful result.

## Tx3 protocol compatibility

Tx3 protocol compatibility: TRP `v1beta0`; TII schema `v1beta0`.

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
