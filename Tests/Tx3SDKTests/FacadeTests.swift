import Foundation
import Testing

@testable import Tx3SDK

private actor FacadeTransport: HTTPTransport {
    private var capturedRequests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        let id = try #require(Self.payload(request)["id"] as? String)
        let body = Data(
            "{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":{\"hash\":\"aabb\",\"tx\":\"ccdd\"}}"
                .utf8
        )
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

    func requests() -> [URLRequest] {
        capturedRequests
    }

    static func payload(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite("High-level facade")
struct FacadeTests {
    private struct Oracle: Decodable {
        struct Vector: Decodable {
            let name: String
            let schema: JSONValue
            let tagged: JSONValue
        }

        let components: [String: JSONValue]
        let accept: [Vector]
    }

    private static var endpoint: URL {
        guard let url = URL(string: "https://trp.example/rpc") else {
            preconditionFailure("The fixture endpoint must be valid")
        }
        return url
    }

    @Test("dynamic and parts clients emit the same captured resolve request")
    func dynamicAndPartsRequestsMatch() async throws {
        let protocolValue = try Protocol.fromFile(fixture("transfer.tii"))
        let transaction = try #require(protocolValue.transactions["transfer"])
        let tir = try JSONDecoder().decode(
            TIREnvelope.self,
            from: JSONEncoder().encode(transaction.tir)
        )
        let profile = Profile(
            environment: ["tax": .number(5_000_000)],
            parties: ["sender": "0011"]
        )
        let dynamicTransport = FacadeTransport()
        let partsTransport = FacadeTransport()
        let override = try Address("0022")

        let dynamic = try protocolValue.client()
            .trp(ClientOptions(endpoint: Self.endpoint, headers: ["X-Base": "base"]))
            .withHeader("X-Trace", "facade")
            .withProfile("preprod")
            .withParty("sender", .address(try Address("0011")))
            .withEnvValue("network", .string("preview"))
            .withTransport(dynamicTransport)
            .build()
        let parts = try Tx3ClientBuilder.fromParts(
            transactions: ["transfer": tir],
            profiles: ["preprod": profile],
            knownParties: ["sender", "receiver", "middleman"]
        )
        .trp(ClientOptions(endpoint: Self.endpoint, headers: ["X-Base": "base"]))
        .withHeader("X-Trace", "facade")
        .withProfile("preprod")
        .withParty("sender", .address(try Address("0011")))
        .withEnvValue("network", .string("preview"))
        .withTransport(partsTransport)
        .build()

        let dynamicResult = try await dynamic.tx("transfer")
            .arg("quantity", 42)
            .argTagged("SENDER", .address(override))
            .resolve()
        let partsResult = try await parts.tx("transfer")
            .argTagged("quantity", .integer(42))
            .argTagged("SENDER", .address(override))
            .resolve()

        #expect(dynamicResult == ResolvedTx(hash: "aabb", txHex: "ccdd"))
        #expect(partsResult == dynamicResult)
        let dynamicRequest = try #require(await dynamicTransport.requests().first)
        let partsRequest = try #require(await partsTransport.requests().first)
        #expect(dynamicRequest.value(forHTTPHeaderField: "X-Base") == "base")
        #expect(dynamicRequest.value(forHTTPHeaderField: "X-Trace") == "facade")
        let dynamicParams = try #require(
            Self.payload(dynamicRequest)["params"] as? NSDictionary
        )
        let partsParams = try #require(Self.payload(partsRequest)["params"] as? NSDictionary)
        #expect(dynamicParams == partsParams)
        let args = try #require(dynamicParams["args"] as? [String: Any])
        #expect((args["sender"] as? [String: String]) == ["address": "0022"])
        let env = try #require(dynamicParams["env"] as? [String: Any])
        #expect(env["tax"] as? Int == 5_000_000)
        #expect(env["network"] as? String == "preview")
    }

    @Test("builder and lookup failures occur at their specified boundary")
    func validationTiming() async throws {
        let protocolValue = try Protocol.fromFile(fixture("transfer.tii"))
        #expect(throws: Tx3Error.construction(.missingTrpEndpoint)) {
            try protocolValue.client().build()
        }
        #expect(throws: Tx3Error.unknownProfile("missing")) {
            try protocolValue.client()
                .trpEndpoint(Self.endpoint)
                .withProfile("missing")
                .build()
        }
        #expect(throws: Tx3Error.unknownParty("stranger")) {
            try protocolValue.client()
                .trpEndpoint(Self.endpoint)
                .withParty("Stranger", .address(try Address("0011")))
                .build()
        }

        let client = try protocolValue.client()
            .trpEndpoint(Self.endpoint)
            .withPartyUnchecked("generated", .address(try Address("0011")))
            .build()
        #expect(throws: Tx3Error.unknownTx("missing")) {
            try client.tx("missing")
        }
        #expect(throws: Tx3Error.unknownParty("stranger")) {
            try client.withParty("Stranger", .address(try Address("0011")))
        }
        _ = client.withPartyUnchecked("generated-late", .address(try Address("0011")))

        _ = try protocolValue.client()
            .trpEndpoint(Self.endpoint)
            .withParty("Stranger", .address(try Address("0011")))
            .withPartyUnchecked("sTRANGER", .address(try Address("0022")))
            .build()
        #expect(throws: Tx3Error.unknownParty("stranger")) {
            try protocolValue.client()
                .trpEndpoint(Self.endpoint)
                .withPartyUnchecked("Stranger", .address(try Address("0011")))
                .withParty("sTRANGER", .address(try Address("0022")))
                .build()
        }
    }

    @Test("builder party bindings preserve validated and unchecked call order")
    func builderPartyBindingOrder() async throws {
        let protocolValue = try Protocol.fromFile(fixture("transfer.tii"))
        let uncheckedLastTransport = FacadeTransport()
        let validatedLastTransport = FacadeTransport()

        let uncheckedLast = try protocolValue.client()
            .trpEndpoint(Self.endpoint)
            .withParty("Sender", .address(try Address("0011")))
            .withPartyUnchecked("sENDER", .address(try Address("0022")))
            .withTransport(uncheckedLastTransport)
            .build()
        let validatedLast = try protocolValue.client()
            .trpEndpoint(Self.endpoint)
            .withPartyUnchecked("SENDER", .address(try Address("0033")))
            .withParty("sender", .address(try Address("0044")))
            .withTransport(validatedLastTransport)
            .build()

        _ = try await uncheckedLast.tx("transfer")
            .arg("quantity", 1)
            .resolve()
        _ = try await validatedLast.tx("transfer")
            .arg("quantity", 1)
            .resolve()

        let uncheckedLastRequest = try #require(await uncheckedLastTransport.requests().first)
        let validatedLastRequest = try #require(await validatedLastTransport.requests().first)
        let uncheckedLastArgs =
            try #require(
                Self.payload(uncheckedLastRequest)["params"] as? [String: Any]
            )["args"] as? [String: Any]
        let validatedLastArgs =
            try #require(
                Self.payload(validatedLastRequest)["params"] as? [String: Any]
            )["args"] as? [String: Any]

        #expect((uncheckedLastArgs?["sender"] as? [String: String]) == ["address": "0022"])
        #expect((validatedLastArgs?["sender"] as? [String: String]) == ["address": "0044"])
    }

    @Test("required arguments fail before transport")
    func missingRequiredArgument() async throws {
        let transport = FacadeTransport()
        let client = try Protocol.fromFile(fixture("transfer.tii"))
            .client()
            .trpEndpoint(Self.endpoint)
            .withTransport(transport)
            .build()

        do {
            _ = try await client.tx("transfer").resolve()
            Issue.record("resolve must reject a missing required argument")
        } catch let error as Tx3Error {
            #expect(error == .resolution(.missingParameter(name: "quantity")))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test("complex native values reach the facade request as canonical tagged arguments")
    func complexFacadeEncoding() async throws {
        let oracle = try loadOracle()
        let list = try #require(oracle.accept.first { $0.name == "list_of_bytes" })
        let record = try #require(oracle.accept.first { $0.name == "record_asset_class" })
        let variant = try #require(oracle.accept.first { $0.name == "variant_side_sell" })
        let protocolValue = try Protocol.fromJSON(
            JSONValue.object([
                "tii": .object(["version": .string("v1beta0")]),
                "protocol": .object([:]),
                "parties": .object([:]),
                "profiles": .object([:]),
                "components": .object(["schemas": .object(oracle.components)]),
                "transactions": .object([
                    "complex": .object([
                        "params": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "items": list.schema,
                                "asset": record.schema,
                                "side": variant.schema,
                            ]),
                            "required": .array([
                                .string("items"), .string("asset"), .string("side"),
                            ]),
                        ]),
                        "tir": .object([
                            "encoding": .string("hex"),
                            "content": .string("00"),
                            "version": .string("v1beta0"),
                        ]),
                    ])
                ]),
            ])
        )
        let transport = FacadeTransport()
        let client = try protocolValue.client()
            .trpEndpoint(Self.endpoint)
            .withTransport(transport)
            .build()

        _ = try await client.tx("complex")
            .args([
                "items": [Data([0xde, 0xad, 0xbe, 0xef]), Data([0xca, 0xfe])],
                "asset": ["policy": Data([0xaa, 0xbb]), "name": Data([0x00, 0x11])],
                "side": ["Sell": ["price": 5]],
            ])
            .resolve()

        let request = try #require(await transport.requests().first)
        let params = try #require(Self.payload(request)["params"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: try #require(params["args"]))
        let actual = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(try tagged(actual["items"]) == tagged(list.tagged))
        #expect(try tagged(actual["asset"]) == tagged(record.tagged))
        #expect(try tagged(actual["side"]) == tagged(variant.tagged))
    }

    private static func payload(_ request: URLRequest) throws -> [String: Any] {
        try FacadeTransport.payload(request)
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func loadOracle() throws -> Oracle {
        try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: fixture("wire-vectors.json")))
    }

    private func tagged(_ value: JSONValue?) throws -> ArgValue {
        try JSONDecoder().decode(ArgValue.self, from: JSONEncoder().encode(try #require(value)))
    }
}
