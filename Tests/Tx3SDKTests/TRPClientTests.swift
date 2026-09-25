import Foundation
import Testing

@testable import Tx3SDK

private actor FixtureTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private var capturedRequests: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        return try await handler(request)
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}

private struct FixtureFailure: Error {}

@Suite("Low-level TRP client")
struct TRPClientTests {
    private static var endpoint: URL {
        guard let url = URL(string: "https://trp.example/rpc") else {
            preconditionFailure("The fixture endpoint must be a valid URL")
        }
        return url
    }

    private static func response(
        status: Int = 200,
        body: String,
        url: URL = endpoint
    ) -> (Data, HTTPURLResponse) {
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )
        else {
            preconditionFailure("The fixture response must be valid")
        }
        return (Data(body.utf8), response)
    }

    private static func requestObject(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("resolve sends the exact JSON-RPC method, parameters, headers, and request ID")
    func resolveRequestAndResponse() async throws {
        let transport = FixtureTransport { _ in
            Self.response(
                body: #"{"jsonrpc":"2.0","id":"1","result":{"hash":"aabb","tx":"ccdd"}}"#
            )
        }
        let client = TRPClient(
            options: ClientOptions(
                endpoint: Self.endpoint,
                headers: ["Authorization": "Bearer secret"]
            ),
            transport: transport
        )
        let result = try await client.resolve(
            ResolveParams(
                tir: TIREnvelope(encoding: .hex, content: "0102", version: "v1"),
                args: ["amount": .integer(42)],
                env: ["network": .string("preview")]
            )
        )

        #expect(result == ResolveResponse(hash: "aabb", tx: "ccdd"))
        let request = try #require(await transport.requests().first)
        #expect(request.url == Self.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

        let payload = try Self.requestObject(request)
        #expect(payload["jsonrpc"] as? String == "2.0")
        #expect(payload["method"] as? String == "trp.resolve")
        #expect(payload["id"] as? String == "1")
        let params = try #require(payload["params"] as? [String: Any])
        #expect((params["tir"] as? [String: Any])?["encoding"] as? String == "hex")
        #expect((params["args"] as? [String: Any])?["amount"] as? [String: String] == ["int": "42"])
        #expect((params["env"] as? [String: Any])?["network"] as? String == "preview")
    }

    @Test("submit encodes witnesses and advances the request ID")
    func submitRequestAndResponse() async throws {
        let transport = FixtureTransport { request in
            let payload = try Self.requestObject(request)
            let id = try #require(payload["id"] as? String)
            let result =
                payload["method"] as? String == "trp.checkStatus"
                ? #"{"statuses":{}}"#
                : #"{"hash":"deadbeef"}"#
            return Self.response(
                body: "{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":\(result)}"
            )
        }
        let client = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint),
            transport: transport
        )
        _ = try await client.checkStatus([])
        let result = try await client.submit(
            SubmitParams(
                tx: BytesEnvelope(content: "aabb", contentType: "cbor"),
                witnesses: [
                    .signature(
                        TxSignature(
                            key: BytesEnvelope(content: "11", contentType: "hex"),
                            signature: BytesEnvelope(content: "22", contentType: "hex"),
                            type: "vkey"
                        )
                    ),
                    .bytes(BytesEnvelope(content: "33", contentType: "cbor")),
                ]
            )
        )

        #expect(result == SubmitResponse(hash: "deadbeef"))
        let requests = await transport.requests()
        let request = try #require(requests.last)
        let payload = try Self.requestObject(request)
        #expect(payload["method"] as? String == "trp.submit")
        #expect(payload["id"] as? String == "2")
        let params = try #require(payload["params"] as? [String: Any])
        #expect((params["tx"] as? [String: Any])?["contentType"] as? String == "cbor")
        let witnesses = try #require(params["witnesses"] as? [[String: Any]])
        let witness = try #require(witnesses.first)
        #expect(witness["type"] as? String == "vkey")
        #expect((witness["key"] as? [String: Any])?["content"] as? String == "11")
        #expect(witnesses.last?["content"] as? String == "33")
    }

    @Test("checkStatus decodes every pinned status field")
    func statusRequestAndResponse() async throws {
        let transport = FixtureTransport { _ in
            Self.response(
                body: #"""
                    {"jsonrpc":"2.0","id":"1","result":{"statuses":{
                      "aabb":{"stage":"confirmed","confirmations":3,"nonConfirmations":1,
                        "confirmedAt":{"slot":42,"blockHash":"ccdd"}},
                      "eeff":{"stage":"rolled_back","confirmations":0,"nonConfirmations":2}
                    }}}
                    """#
            )
        }
        let client = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint),
            transport: transport
        )
        let result = try await client.checkStatus(["aabb", "eeff"])

        #expect(
            result.statuses["aabb"]
                == TransactionStatus(
                    stage: .confirmed,
                    confirmations: 3,
                    nonConfirmations: 1,
                    confirmedAt: ChainPoint(slot: 42, blockHash: "ccdd")
                )
        )
        #expect(result.statuses["eeff"]?.stage == .rolledBack)
        let request = try #require(await transport.requests().first)
        let payload = try Self.requestObject(request)
        #expect(payload["method"] as? String == "trp.checkStatus")
        #expect((payload["params"] as? [String: Any])?["hashes"] as? [String] == ["aabb", "eeff"])
    }

    @Test("network, HTTP, JSON-RPC, and malformed failures stay distinguishable")
    func failureCategories() async throws {
        let network = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint),
            transport: FixtureTransport { _ in throw FixtureFailure() }
        )
        await expectTransportFailure(.network(context: "FixtureFailure()")) {
            try await network.checkStatus([])
        }

        let http = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint),
            transport: FixtureTransport { _ in Self.response(status: 503, body: "unavailable") }
        )
        await expectTransportFailure(.httpStatus(code: 503, body: "unavailable")) {
            try await http.checkStatus([])
        }

        let rpc = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint),
            transport: FixtureTransport { _ in
                Self.response(
                    body: #"""
                        {"jsonrpc":"2.0","id":"1",
                         "error":{"code":-32001,"message":"missing amount"}}
                        """#
                )
            }
        )
        await expectTransportFailure(.jsonRPC(code: -32001, message: "missing amount")) {
            try await rpc.checkStatus([])
        }

        let malformed = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint),
            transport: FixtureTransport { _ in
                Self.response(
                    body: #"""
                        {"jsonrpc":"2.0","id":"1","result":{"statuses":{
                          "aabb":{"stage":"future","confirmations":0,"nonConfirmations":0}
                        }}}
                        """#
                )
            }
        )
        do {
            _ = try await malformed.checkStatus(["aabb"])
            Issue.record("An unknown status stage must not decode as success")
        } catch Tx3Error.transport(.malformedResponse) {
        } catch {
            Issue.record("Expected malformed response, got \(error)")
        }
    }

    @Test("timeout cancels controlled transport work and reports timeout")
    func timeout() async {
        let client = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint, timeout: .milliseconds(10)),
            transport: FixtureTransport { _ in
                try await Task.sleep(for: .seconds(60))
                return Self.response(body: "")
            }
        )
        await expectTransportFailure(.timeout) {
            try await client.checkStatus([])
        }
    }

    @Test("caller cancellation becomes the typed cancellation failure")
    func cancellation() async {
        let client = TRPClient(
            options: ClientOptions(endpoint: Self.endpoint),
            transport: FixtureTransport { _ in
                try await Task.sleep(for: .seconds(60))
                return Self.response(body: "")
            }
        )
        let task = Task { try await client.checkStatus([]) }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must not produce a successful response")
        } catch Tx3Error.transport(.cancelled) {
        } catch {
            Issue.record("Expected typed cancellation, got \(error)")
        }
    }

    private func expectTransportFailure<T: Sendable>(
        _ expected: TransportFailure,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected transport failure \(expected)")
        } catch let error as Tx3Error {
            #expect(error == .transport(expected))
        } catch {
            Issue.record("Expected Tx3Error, got \(error)")
        }
    }
}
