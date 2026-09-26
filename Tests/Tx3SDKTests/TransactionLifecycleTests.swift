import Foundation
import Testing

@testable import Tx3SDK

private actor LifecycleTransport: HTTPTransport {
    private var results: [String]
    private var captured: [URLRequest] = []

    init(results: [String]) {
        self.results = results
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        let payload = try Self.payload(request)
        let id = try #require(payload["id"] as? String)
        let result = try #require(results.first)
        results.removeFirst()
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":\(result)}".utf8)
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )
        )
        return (body, response)
    }

    func requests() -> [URLRequest] { captured }

    static func payload(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

private actor BlockingTransport: HTTPTransport {
    private var started = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        let stream = AsyncStream<Void> { _ in }
        for await _ in stream {}
        try Task.checkCancellation()
        throw CancellationError()
    }

    func isSending() -> Bool { started }
}

private actor ImmediateClock: PollClock {
    private var recorded: [Duration] = []

    func sleep(for duration: Duration) async throws {
        recorded.append(duration)
    }

    func sleeps() -> [Duration] { recorded }
}

private actor NeverClock: PollClock {
    private var started = false

    func sleep(for duration: Duration) async throws {
        started = true
        let stream = AsyncStream<Void> { _ in }
        for await _ in stream {}
        try Task.checkCancellation()
    }

    func isSleeping() -> Bool { started }
}

private struct CapturingSigner: Signer {
    let boundAddress: Address
    let marker: String

    func address() -> Address { boundAddress }

    func sign(_ request: SignRequest) throws -> Witness {
        Witness(
            publicKeyHex: marker + request.txHashHex,
            signatureHex: marker + request.txCborHex,
            type: .vkey
        )
    }
}

private struct FailingSigner: Signer {
    let boundAddress: Address

    func address() -> Address { boundAddress }

    func sign(_ request: SignRequest) throws -> Witness {
        throw Tx3Error.signing(.invalidKey)
    }
}

@Suite("Transaction lifecycle")
struct TransactionLifecycleTests {
    private static let hash = String(repeating: "ab", count: 32)

    private static var endpoint: URL {
        guard let url = URL(string: "https://trp.example/rpc") else {
            preconditionFailure("The fixture endpoint must be valid")
        }
        return url
    }

    @Test("complete chain preserves signer and manual witness order and signing inputs")
    func completeChain() async throws {
        let transport = LifecycleTransport(results: [
            "{\"hash\":\"\(Self.hash)\",\"tx\":\"cafe\"}",
            "{\"hash\":\"\(Self.hash)\"}",
            "{\"statuses\":{\"\(Self.hash)\":{\"stage\":\"pending\",\"confirmations\":0,\"nonConfirmations\":0}}}",
            "{\"statuses\":{\"\(Self.hash)\":{\"stage\":\"confirmed\",\"confirmations\":2,\"nonConfirmations\":0}}}",
        ])
        let first = CapturingSigner(boundAddress: try Address("0011"), marker: "11")
        let second = CapturingSigner(boundAddress: try Address("0022"), marker: "22")
        let client = try Tx3ClientBuilder.fromParts(
            transactions: ["transfer": TIREnvelope(encoding: .hex, content: "00", version: "v1")],
            profiles: [:],
            knownParties: ["first", "second"]
        )
        .trpEndpoint(Self.endpoint)
        .withParty("second", .signer(second))
        .withParty("first", .signer(first))
        .withTransport(transport)
        .build()

        let manual = TxWitness.bytes(BytesEnvelope(content: "33", contentType: "hex"))
        let resolved = try await client.tx("transfer").resolve().addWitness(manual)
        #expect(resolved.hash == Self.hash)
        #expect(resolved.signingHash == Self.hash)
        #expect(resolved.txHex == "cafe")

        let signed = try resolved.sign()
        #expect(signed.hash == Self.hash)
        #expect(signed.submitParams.tx == BytesEnvelope(content: "cafe", contentType: "hex"))
        #expect(
            signed.submitParams.witnesses == [
                Self.signature(marker: "22"),
                Self.signature(marker: "11"),
                manual,
            ]
        )

        let submitted = try await signed.submit()
        let clock = ImmediateClock()
        let pollable = SubmittedTx(trp: submitted.trp, hash: submitted.hash, clock: clock)
        let status = try await pollable.waitForConfirmed(
            PollConfig(attempts: 2, delay: .seconds(7))
        )
        #expect(status.stage == .confirmed)
        #expect(await clock.sleeps() == [.seconds(7)])

        let requests = await transport.requests()
        #expect(requests.count == 4)
        let submit = try #require(Self.payload(requests[1])["params"] as? [String: Any])
        let witnesses = try #require(submit["witnesses"] as? [[String: Any]])
        #expect((witnesses[0]["key"] as? [String: String])?["content"] == "22" + Self.hash)
        #expect((witnesses[0]["signature"] as? [String: String])?["content"] == "22cafe")
        #expect((witnesses[1]["key"] as? [String: String])?["content"] == "11" + Self.hash)
        #expect(witnesses[2]["content"] as? String == "33")
    }

    @Test("external witnesses can sign without a registered signer")
    func externalWitnessOnly() async throws {
        let transport = LifecycleTransport(results: [
            "{\"hash\":\"\(Self.hash)\",\"tx\":\"cafe\"}"
        ])
        let client = try Self.bareClient(transport: transport)
        let external = Witness(publicKeyHex: "11", signatureHex: "22", type: .vkey)

        let signed = try await client.tx("transfer").resolve().addWitness(external).sign()

        #expect(signed.submitParams.witnesses == [Self.signature(key: "11", signature: "22")])
    }

    @Test("typed signing and submit-hash failures are preserved")
    func signingAndSubmissionFailures() async throws {
        let signingTransport = LifecycleTransport(results: [
            "{\"hash\":\"\(Self.hash)\",\"tx\":\"cafe\"}"
        ])
        let client = try Tx3ClientBuilder.fromParts(
            transactions: ["transfer": TIREnvelope(encoding: .hex, content: "00", version: "v1")],
            profiles: [:],
            knownParties: ["sender"]
        )
        .trpEndpoint(Self.endpoint)
        .withParty("sender", .signer(FailingSigner(boundAddress: try Address("00"))))
        .withTransport(signingTransport)
        .build()
        let resolved = try await client.tx("transfer").resolve()
        #expect(throws: Tx3Error.signing(.invalidKey)) {
            try resolved.sign()
        }

        let mismatchTransport = LifecycleTransport(results: [
            "{\"hash\":\"different\"}"
        ])
        let mismatchClient = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint),
            transport: mismatchTransport
        )
        let signed = SignedTx(
            trp: mismatchClient,
            hash: Self.hash,
            submitParams: SubmitParams(
                tx: BytesEnvelope(content: "cafe", contentType: "hex"),
                witnesses: []
            )
        )
        await #expect(throws: Tx3Error.submission(.hashMismatch)) {
            try await signed.submit()
        }
    }

    @Test("confirmed and finalized waits use distinct success thresholds")
    func waitThresholds() async throws {
        let confirmedTransport = LifecycleTransport(results: [
            Self.statusResult(.finalized)
        ])
        let confirmed = SubmittedTx(
            trp: Self.client(transport: confirmedTransport),
            hash: Self.hash,
            clock: ImmediateClock()
        )
        #expect(
            try await confirmed.waitForConfirmed(PollConfig(attempts: 1, delay: .zero)).stage
                == TransactionStage.finalized
        )

        let finalizedTransport = LifecycleTransport(results: [
            Self.statusResult(.confirmed), Self.statusResult(.finalized),
        ])
        let clock = ImmediateClock()
        let finalized = SubmittedTx(
            trp: Self.client(transport: finalizedTransport),
            hash: Self.hash,
            clock: clock
        )
        #expect(
            try await finalized.waitForFinalized(PollConfig(attempts: 2, delay: .seconds(3))).stage
                == TransactionStage.finalized
        )
        #expect(await clock.sleeps() == [.seconds(3)])
    }

    @Test("terminal, rollback, exhaustion, and cancellation failures stay distinct")
    func pollingFailures() async throws {
        let dropped = SubmittedTx(
            trp: Self.client(
                transport: LifecycleTransport(results: [Self.statusResult(.dropped)])
            ),
            hash: Self.hash
        )
        await #expect(throws: Tx3Error.polling(.terminal(stage: "dropped"))) {
            try await dropped.waitForConfirmed(PollConfig(attempts: 1, delay: .zero))
        }

        let rolledBack = SubmittedTx(
            trp: Self.client(
                transport: LifecycleTransport(results: [Self.statusResult(.rolledBack)])
            ),
            hash: Self.hash
        )
        await #expect(throws: Tx3Error.polling(.rolledBack)) {
            try await rolledBack.waitForConfirmed(PollConfig(attempts: 1, delay: .zero))
        }

        let exhausted = SubmittedTx(
            trp: Self.client(
                transport: LifecycleTransport(results: [
                    Self.statusResult(.pending), Self.statusResult(.pending),
                ])
            ),
            hash: Self.hash,
            clock: ImmediateClock()
        )
        await #expect(throws: Tx3Error.polling(.exhausted)) {
            try await exhausted.waitForConfirmed(PollConfig(attempts: 2, delay: .zero))
        }

        let neverClock = NeverClock()
        let cancellation = SubmittedTx(
            trp: Self.client(
                transport: LifecycleTransport(results: [Self.statusResult(.pending)])
            ),
            hash: Self.hash,
            clock: neverClock
        )
        let task = Task {
            try await cancellation.waitForConfirmed(PollConfig(attempts: 2, delay: .seconds(5)))
        }
        while await !neverClock.isSleeping() {
            await Task.yield()
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must fail with the polling cancellation case")
        } catch let error as Tx3Error {
            #expect(error == .polling(.cancelled))
        }

        let blockingTransport = BlockingTransport()
        let statusCancellation = SubmittedTx(
            trp: Self.client(transport: blockingTransport),
            hash: Self.hash,
            clock: ImmediateClock()
        )
        let statusTask = Task {
            try await statusCancellation.waitForConfirmed(
                PollConfig(attempts: 1, delay: .zero)
            )
        }
        while await !blockingTransport.isSending() {
            await Task.yield()
        }
        statusTask.cancel()
        do {
            _ = try await statusTask.value
            Issue.record("Cancellation must cancel in-flight status work")
        } catch let error as Tx3Error {
            #expect(error == .polling(.cancelled))
        }
    }

    @Test("poll configuration rejects invalid boundaries")
    func pollConfigurationValidation() {
        #expect(
            throws: Tx3Error.validation(
                .invalidValue(context: "PollConfig attempts must be positive")
            )
        ) {
            try PollConfig(attempts: 0)
        }
        #expect(
            throws: Tx3Error.validation(
                .invalidValue(context: "PollConfig delay must not be negative")
            )
        ) {
            try PollConfig(delay: .seconds(-1))
        }
        let defaults = try? PollConfig()
        #expect(defaults?.attempts == 20)
        #expect(defaults?.delay == .seconds(5))
    }

    private static func bareClient(transport: any HTTPTransport) throws -> Tx3Client {
        try Tx3ClientBuilder.fromParts(
            transactions: ["transfer": TIREnvelope(encoding: .hex, content: "00", version: "v1")],
            profiles: [:],
            knownParties: []
        )
        .trpEndpoint(endpoint)
        .withTransport(transport)
        .build()
    }

    private static func client(transport: any HTTPTransport) -> TRPClient {
        TRPClient(options: ClientOptions(endpoint: endpoint), transport: transport)
    }

    private static func statusResult(_ stage: TransactionStage) -> String {
        "{\"statuses\":{\"\(hash)\":{\"stage\":\"\(stage.rawValue)\",\"confirmations\":0,\"nonConfirmations\":0}}}"
    }

    private static func signature(marker: String) -> TxWitness {
        signature(key: marker + hash, signature: marker + "cafe")
    }

    private static func signature(key: String, signature: String) -> TxWitness {
        .signature(
            TxSignature(
                key: BytesEnvelope(content: key, contentType: "hex"),
                signature: BytesEnvelope(content: signature, contentType: "hex"),
                type: "vkey"
            )
        )
    }

    private static func payload(_ request: URLRequest) throws -> [String: Any] {
        try LifecycleTransport.payload(request)
    }
}
