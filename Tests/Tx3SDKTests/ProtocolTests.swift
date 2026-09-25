import Foundation
import Testing

@testable import Tx3SDK

@Suite("TII protocol loading")
struct ProtocolTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test("all supported inputs produce equivalent protocols")
    func supportedInputs() throws {
        let url = try fixture("transfer.tii")
        let data = try Data(contentsOf: url)
        let string = try String(contentsOf: url, encoding: .utf8)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: data)

        let fromFile = try Protocol.fromFile(url)
        #expect(try Protocol.fromJSON(data) == fromFile)
        #expect(try Protocol.fromJSON(string) == fromFile)
        #expect(try Protocol.fromJSON(parsed) == fromFile)
        #expect(fromFile.transactions.keys.sorted() == ["transfer"])
        #expect(fromFile.parties.keys.sorted() == ["middleman", "receiver", "sender"])
        #expect(fromFile.profiles.keys.sorted() == ["local", "preprod"])
        #expect(fromFile.environmentParameters["tax"] == .integer)
        #expect(fromFile.transactions["transfer"]?.parameters["quantity"] == .integer)
        #expect(fromFile.transactions["transfer"]?.requiredParameters == ["quantity"])
        _ = fromFile.client()
    }

    @Test("complex fixture retains TIR and interprets every parameter shape")
    func complexFixture() throws {
        let protocolValue = try Protocol.fromFile(fixture("complex.tii"))
        let transaction = try #require(protocolValue.transactions["complex"])
        let parameters = transaction.parameters

        #expect(parameters["quantity"] == .integer)
        #expect(parameters["flag"] == .boolean)
        #expect(parameters["nothing"] == .unit)
        #expect(parameters["recipient"] == .address)
        #expect(parameters["source"] == .utxoRef)
        #expect(parameters["bag"] == .anyAsset)
        #expect(parameters["amounts"] == .list(.integer))
        #expect(parameters["pair"] == .tuple([.integer, .bytes]))
        #expect(parameters["labels"] == .map(.integer))
        #expect(
            parameters["asset"]
                == .record([
                    ParamField(name: "policy", type: .bytes),
                    ParamField(name: "name", type: .bytes),
                ])
        )
        #expect(
            parameters["side"]
                == .variant([
                    ParamCase(name: "Buy", fields: .record([])),
                    ParamCase(
                        name: "Sell",
                        fields: .record([ParamField(name: "price", type: .integer)])
                    ),
                ])
        )
        #expect(protocolValue.environmentParameters["fee"] == .integer)
        #expect(protocolValue.componentSchemas.keys.sorted() == ["AssetClass", "Side"])

        guard case .object(let tir) = transaction.tir else {
            Issue.record("The transaction must retain its TIR envelope")
            return
        }
        #expect(tir["encoding"] == .string("hex"))
        #expect(tir["content"] != nil)
    }

    @Test("scalar refs match trailing names in canonical and legacy forms")
    func scalarReferences() throws {
        let expected: [(String, ParamType)] = [
            ("Bytes", .bytes),
            ("Address", .address),
            ("UtxoRef", .utxoRef),
            ("Utxo", .utxo),
            ("AnyAsset", .anyAsset),
        ]
        for (name, type) in expected {
            let canonical = try schema(
                #"{"$ref":"https://tx3.land/specs/v1beta0/tii#/$defs/\#(name)"}"#
            )
            let legacy = try schema(
                #"{"$ref":"https://tx3.land/specs/v1beta0/core#\#(name)"}"#
            )
            #expect(ParamType.fromJSONSchema(canonical) == type)
            #expect(ParamType.fromJSONSchema(legacy) == type)
        }
    }

    @Test("record and variant order follow required and oneOf")
    func declaredOrder() throws {
        let record = try schema(
            #"{"type":"object","additionalProperties":false,"properties":{"a":{"type":"integer"},"m":{"type":"null"},"z":{"type":"boolean"}},"required":["z","a"]}"#
        )
        #expect(
            ParamType.fromJSONSchema(record)
                == .record([
                    ParamField(name: "z", type: .boolean),
                    ParamField(name: "a", type: .integer),
                ])
        )

        let variant = try schema(
            #"{"oneOf":[{"type":"object","additionalProperties":false,"required":["Second"],"properties":{"Second":{"type":"object","properties":{},"required":[]}}},{"type":"object","additionalProperties":false,"required":["First"],"properties":{"First":{"type":"object","properties":{},"required":[]}}}]}"#
        )
        #expect(
            ParamType.fromJSONSchema(variant)
                == .variant([
                    ParamCase(name: "Second", fields: .record([])),
                    ParamCase(name: "First", fields: .record([])),
                ])
        )
    }

    @Test("recursive components stop at a named reference")
    func recursiveComponent() throws {
        let node = try schema(
            ##"{"type":"object","properties":{"next":{"$ref":"#/components/schemas/Node"}},"required":["next"]}"##
        )
        let reference = try schema(##"{"$ref":"#/components/schemas/Node"}"##)
        #expect(
            ParamType.fromJSONSchema(reference, components: ["Node": node])
                == .record([ParamField(name: "next", type: .namedReference("Node"))])
        )
    }

    @Test("unknown schemas retain their original JSON")
    func unknownSchema() throws {
        let bareString = try schema(#"{"type":"string","description":"not an address"}"#)
        let unsupportedItems = try schema(#"{"type":"array","items":false}"#)
        #expect(ParamType.fromJSONSchema(bareString) == .unknown(bareString))
        #expect(ParamType.fromJSONSchema(unsupportedItems) == .unknown(unsupportedItems))
    }

    @Test("loader failures use safe discriminated protocol errors")
    func loaderFailures() throws {
        let missing = try fixture("does-not-exist.tii")
        #expect(throws: Tx3Error.protocolError(.unreadable(path: missing.path))) {
            try Protocol.fromFile(missing)
        }
        #expect(throws: Tx3Error.protocolError(.invalidJSON(context: "JSON document"))) {
            try Protocol.fromJSON(#"{"secret":"do not echo","#)
        }
        #expect(throws: Tx3Error.protocolError(.invalidSchema(context: "$.transactions"))) {
            try Protocol.fromJSON(#"{"tii":{},"protocol":{},"parties":{},"profiles":{}}"#)
        }
    }

    private func schema(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
