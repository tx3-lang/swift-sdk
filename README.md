# Tx3 Swift SDK

`Tx3SDK` is the Swift package for loading Tx3 protocol interfaces and building,
resolving, signing, submitting, and tracking transactions. Use the dynamic API
with a `.tii` file, or generate a typed client with `tx3c`.

The initial release line is `0.15.x`. It supports macOS 14 or newer and iOS 18
or newer with Swift 6.1 and Swift Package Manager.

## Installation

Add the package in `Package.swift` and depend on the `Tx3SDK` product:

```swift
.package(url: "https://github.com/tx3-lang/swift-sdk", from: "0.15.0")
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
`Protocol.client()` is the single bridge into the dynamic client-builder flow.

## Build and resolve a transaction

Configure the endpoint and optional profile, party, header, and environment
values with the value-semantic client builder. Optional name validation is
deferred until `build()` so configuration chains remain fluent:

```swift
let client = try Protocol.fromFile(tiiURL)
    .client()
    .trpEndpoint(URL(string: "https://trp.example/rpc")!)
    .withProfile("preprod")
    .withHeader("Authorization", "Bearer …")
    .withParty("sender", .address(try Address("001122aabbcc")))
    .withEnvValue("network", .string("preview"))
    .build()

let resolved = try await client
    .tx("transfer")
    .arg("quantity", 10_000_000)
    .resolve()

let submitted = try await resolved.sign().submit()
let confirmed = try await submitted.waitForConfirmed(PollConfig())
let finalized = try await submitted.waitForFinalized(PollConfig())
print(submitted.hash, confirmed.stage, finalized.stage)
```

`build()` distinguishes missing TRP configuration, unknown profiles, and
unknown parties through `Tx3Error`. Transaction lookup reports `unknownTx`, and
missing or invalid arguments fail before transport. Explicit transaction
arguments override injected party addresses and environment values; explicit
environment values override the selected profile. Environment values, parties,
and transaction arguments are sent together in the resolver `args` map. Built
clients do not expose profile switching.

Generated bindings seed the same builder with
`Tx3ClientBuilder.fromParts(transactions:profiles:knownParties:)` and provide
statically constructed `ArgValue` values through `TxBuilder.argTagged`. They do
not carry a TII schema or use a separate client or resolution path. Generate and
build a typed package with the tx3c version pinned by your project:

```console
tx3c codegen \
  --tii ./transfer.tii \
  --template swift-client \
  --output ./Generated/TransferClient
swift build --package-path ./Generated/TransferClient
```

The generated module exposes protocol-specific parameters, party setters, and
transaction methods while returning the SDK's normal lifecycle values:

```swift
import Tx3SDK
import UnknownClient

let generated = UnknownClient(
    options: ClientOptions(endpoint: endpoint),
    profile: .preprod
)
.withSender(.signer(signer))
.withReceiver(.address(receiver))
.withMiddleman(.address(receiver))

let submitted = try await generated
    .transfer(TransferParams(quantity: 10_000_000))
    .resolve()
    .sign()
    .submit()
```

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

`ResolvedTx.sign()` creates ordered signer witnesses, `SignedTx.submit()` checks
the returned hash, and `SubmittedTx` can wait independently for confirmation or
finalization. These methods surface typed signing, submission, polling, and
transport errors; an unavailable operation is never represented as success.

## Live preprod tests

The e2e suite loads the canonical transfer TII and exercises load, configure,
resolve, sign, submit, and a confirmed wait against TRP. The live suite stops at
confirmed; finalized-wait behavior remains covered by mocked-TRP unit tests. Set
all six canonical variables, then select the suite explicitly:

```console
TRP_ENDPOINT_PREPROD=https://preprod.trp.example \
TRP_API_KEY_PREPROD=… \
TEST_PARTY_A_ADDRESS=addr_test1… \
TEST_PARTY_A_MNEMONIC="…" \
TEST_PARTY_B_ADDRESS=addr_test1… \
TEST_PARTY_B_MNEMONIC="…" \
swift test --filter Tx3SDKE2ETests --parallel
```

The selected suite reports a local skip when configuration is absent. CI maps
the same names from repository secrets and fails before testing if any is empty.

## Releases

SwiftPM distributes this repository directly from annotated
`vMAJOR.MINOR.PATCH` tags. The current fleet train and manifest version are
`0.15`, beginning with `v0.15.0`. The tag workflow validates the annotated tag,
package version, source contents, release build, unit tests, and an exact-version
external consumer before completing. Tag creation and GitHub Release publication
remain maintainer operations; no registry credentials are used.

## Tx3 protocol compatibility

Tx3 protocol compatibility: TRP `v1beta0`; TII schema `v1beta0`.

## Development

Use Xcode 16.4 / Swift 6.1. From the repository root, run:

```console
swift package resolve
swift build --configuration debug
swift format lint --strict --recursive Sources Tests
swift test --filter Tx3SDKTests --parallel
bash .github/scripts/consumer-check.sh
bash .github/scripts/codegen-check.sh
```

Unit tests never require credentials. `codegen-check.sh` expects the accepted
`tx3c` with the built-in `swift-client` template on `PATH`; CI installs its
pinned revision.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
