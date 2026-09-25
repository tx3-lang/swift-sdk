import BigInt
import Foundation
import Testing

@testable import Tx3SDK

@Suite("Contract types")
struct ContractTypesTests {
    @Test("hex addresses validate and round-trip")
    func addressRoundTrip() throws {
        let address = try Address("001122aabbcc")
        let data = try JSONEncoder().encode(address)
        #expect(try JSONDecoder().decode(Address.self, from: data) == address)
    }

    @Test("invalid addresses use the typed validation error")
    func invalidAddress() {
        #expect(throws: Tx3Error.validation(.invalidAddress("not an address"))) {
            try Address("not an address")
        }
    }

    @Test("integer convenience inputs promote losslessly")
    func integerPromotion() {
        let platform: Int = .max
        let fixed: Int64 = .min
        #expect(ArgValue.integer(platform) == .integer(BigInt(platform)))
        #expect(ArgValue.integer(fixed) == .integer(BigInt(fixed)))
    }

    @Test("recursive tagged values serialize deterministically")
    func taggedValueSerialization() throws {
        guard let largeInteger = BigInt("170141183460469231731687303715884105727", radix: 10)
        else {
            Issue.record("The fixed signed-i128 boundary must be a valid BigInt")
            return
        }
        let value = ArgValue.structure(
            constructor: 3,
            fields: [
                .integer(largeInteger),
                .bytes(Data([0xde, 0xad, 0xbe, 0xef])),
                .mapPairs([.init(key: .string("enabled"), value: .boolean(true))]),
                .utxoRef(UtxoRef(txId: Data([0xaa, 0xbb]), index: 2)),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        #expect(try JSONDecoder().decode(ArgValue.self, from: data) == value)
        #expect(
            String(decoding: data, as: UTF8.self)
                == #"{"struct":{"constructor":3,"fields":[{"int":"170141183460469231731687303715884105727"},{"bytes":"0xdeadbeef"},{"map":[[{"string":"enabled"},{"bool":true}]]},{"utxoRef":"aabb#2"}]}}"#
        )
    }

    @Test("shared complex-type wire shapes decode canonically")
    func sharedWireShapes() throws {
        let decoder = JSONDecoder()

        let unprefixedBytes = try decoder.decode(
            ArgValue.self,
            from: Data(#"{"bytes":"deadbeef"}"#.utf8)
        )
        #expect(unprefixedBytes == .bytes(Data([0xde, 0xad, 0xbe, 0xef])))

        let map = try decoder.decode(
            ArgValue.self,
            from: Data(
                #"{"map":[[{"string":"1"},{"int":100}],[{"string":"2"},{"int":200}]]}"#.utf8
            )
        )
        #expect(
            map
                == .mapPairs([
                    .init(key: .string("1"), value: .integer(BigInt(100))),
                    .init(key: .string("2"), value: .integer(BigInt(200))),
                ])
        )

        let utxo = try decoder.decode(
            ArgValue.self,
            from: Data(#"{"utxoRef":"aabb#2"}"#.utf8)
        )
        #expect(utxo == .utxoRef(UtxoRef(txId: Data([0xaa, 0xbb]), index: 2)))
    }

    @Test("signing values use stable field names")
    func signingValueSerialization() throws {
        let witness = Witness(publicKeyHex: "aabb", signatureHex: "ccdd", type: .vkey)
        let data = try JSONEncoder().encode(witness)
        #expect(try JSONDecoder().decode(Witness.self, from: data) == witness)
    }

    @Test("error categories are distinguishable without text matching")
    func errorDiscrimination() {
        let errors: [Tx3Error] = [
            Tx3Error.protocolError(.invalidSchema(context: "schema")),
            .unknownTx("transfer"),
            .unknownProfile("preview"),
            .unknownParty("sender"),
            .construction(.missingTrpEndpoint),
            .validation(.integerOutOfRange(path: "$", expected: "signed i128 integer")),
            .transport(.timeout),
            .resolution(.missingParameter(name: "amount")),
            .signing(.invalidKey),
            .submission(.hashMismatch),
            .polling(.exhausted),
        ]
        var categories = Set<Int>()
        for error in errors {
            switch error {
            case .protocolError: categories.insert(0)
            case .unknownTx: categories.insert(1)
            case .unknownProfile: categories.insert(2)
            case .unknownParty: categories.insert(3)
            case .construction: categories.insert(4)
            case .validation: categories.insert(5)
            case .transport: categories.insert(6)
            case .resolution: categories.insert(7)
            case .signing: categories.insert(8)
            case .submission: categories.insert(9)
            case .polling: categories.insert(10)
            }
        }
        #expect(categories.count == errors.count)
    }
}
