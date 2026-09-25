import BigInt
import Foundation
import Testing

@testable import Tx3SDK

@Suite("Argument encoding")
struct ArgEncoderTests {
    private struct Oracle: Decodable {
        let components: [String: JSONValue]
        let accept: [AcceptVector]
        let reject: [RejectVector]
    }

    private struct AcceptVector: Decodable {
        let name: String
        let schema: JSONValue
        let value: JSONValue
        let tagged: JSONValue
    }

    private struct RejectVector: Decodable {
        let name: String
        let schema: JSONValue
        let value: JSONValue
    }

    @Test("all shared accept vectors encode to the canonical tagged value")
    func sharedAcceptVectors() throws {
        let oracle = try loadOracle()

        for vector in oracle.accept {
            let type = ParamType.fromJSONSchema(vector.schema, components: oracle.components)
            let native = try nativeValue(vector.value, as: type)
            let actual = try ArgEncoder.encode(native, as: type)
            let expected = try JSONDecoder().decode(
                ArgValue.self,
                from: JSONEncoder().encode(vector.tagged)
            )
            #expect(actual == expected, "wire vector \(vector.name)")
        }
    }

    @Test("all shared reject vectors fail before transport")
    func sharedRejectVectors() throws {
        let oracle = try loadOracle()

        for vector in oracle.reject {
            let type = ParamType.fromJSONSchema(vector.schema, components: oracle.components)
            let native = try nativeValue(vector.value, as: type)
            do {
                _ = try ArgEncoder.encode(native, as: type)
                Issue.record("wire vector \(vector.name) was accepted")
            } catch let error as Tx3Error {
                guard case .resolution(.invalidArgument) = error else {
                    Issue.record("wire vector \(vector.name) failed with \(error)")
                    continue
                }
            }
        }
    }

    @Test("native scalar contracts preserve precision and canonical bytes")
    func scalarContracts() throws {
        let maximum = (BigInt(1) << 127) - 1
        let encoded = try ArgEncoder.encode(maximum, as: .integer)
        let encodedJSON = try JSONEncoder().encode(encoded)
        #expect(
            String(decoding: encodedJSON, as: UTF8.self)
                == #"{"int":"170141183460469231731687303715884105727"}"#
        )

        let bytes = try ArgEncoder.encode(Data([0xde, 0xad, 0xbe, 0xef]), as: .bytes)
        #expect(
            String(decoding: try JSONEncoder().encode(bytes), as: UTF8.self)
                == #"{"bytes":"0xdeadbeef"}"#
        )

        #expect(throws: Tx3Error.validation(.integerOutOfRange)) {
            try ArgEncoder.encode(BigInt(1) << 127, as: .integer)
        }
        let floatingPointError = Tx3Error.resolution(
            .invalidArgument(path: "$", expected: "BigInt, Int, or Int64")
        )
        #expect(throws: floatingPointError) {
            try ArgEncoder.encode(1.0, as: .integer)
        }

        let address = try Address("001122aabbcc")
        #expect(try ArgEncoder.encode(address, as: .address) == .address(address))
        let reference = UtxoRef(txId: Data([0xaa, 0xbb]), index: 2)
        #expect(try ArgEncoder.encode(reference, as: .utxoRef) == .utxoRef(reference))
    }

    @Test("parameter lookup and tagged builder writes are case-insensitive")
    func caseInsensitiveSeams() throws {
        let transaction = Transaction(
            tir: .object([:]),
            parameterSchema: .object([:]),
            parameters: ["Quantity": .integer],
            requiredParameters: ["Quantity"]
        )
        #expect(try ArgEncoder.encode(7, for: "quantity", in: transaction) == .integer(7))

        let canonical = ArgValue.list([.integer(1)])
        let builder = TxBuilder().argTagged("Items", canonical).argTagged("ITEMS", canonical)
        #expect(builder.taggedArguments == ["items": canonical])
    }

    @Test("passthrough types retain JSON without type-directed rewriting")
    func passthrough() throws {
        let value = JSONValue.object([
            "items": .array([.number(1), .string("raw")]),
            "ok": .boolean(true),
        ])
        #expect(try ArgEncoder.encode(value, as: .unknown(.null)) == .json(value))
        #expect(try ArgEncoder.encode(value, as: .utxo) == .json(value))
        #expect(try ArgEncoder.encode(value, as: .anyAsset) == .json(value))
    }

    private func loadOracle() throws -> Oracle {
        let url = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("wire-vectors.json")
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    private func nativeValue(_ value: JSONValue, as type: ParamType) throws -> Any {
        switch type {
        case .integer:
            guard case .number(let number) = value, number.rounded() == number,
                let integer = Int64(exactly: number)
            else { return looseNativeValue(value) }
            return integer
        case .bytes:
            guard case .string(let string) = value else { return looseNativeValue(value) }
            return try hexData(string)
        case .list(let element):
            guard case .array(let values) = value else { return looseNativeValue(value) }
            return try values.map { try nativeValue($0, as: element) }
        case .tuple(let elements):
            guard case .array(let values) = value, values.count == elements.count else {
                return looseNativeValue(value)
            }
            return try zip(values, elements).map { try nativeValue($0.0, as: $0.1) }
        case .map(let element):
            guard case .object(let values) = value else { return looseNativeValue(value) }
            return try values.mapValues { try nativeValue($0, as: element) }
        case .record(let fields):
            guard case .object(let values) = value else { return looseNativeValue(value) }
            var result: [String: Any] = [:]
            for (name, fieldValue) in values {
                if let field = fields.first(where: { $0.name == name }) {
                    result[name] = try nativeValue(fieldValue, as: field.type)
                } else {
                    result[name] = looseNativeValue(fieldValue)
                }
            }
            return result
        case .variant(let cases):
            guard case .object(let values) = value else { return looseNativeValue(value) }
            var result: [String: Any] = [:]
            for (name, payload) in values {
                if let variant = cases.first(where: { $0.name == name }) {
                    result[name] = try nativeValue(payload, as: variant.fields)
                } else {
                    result[name] = looseNativeValue(payload)
                }
            }
            return result
        default:
            return looseNativeValue(value)
        }
    }

    private func looseNativeValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .boolean(let value): value
        case .number(let value): Int64(exactly: value) ?? value
        case .string(let value): value
        case .array(let values): values.map(looseNativeValue)
        case .object(let values): values.mapValues(looseNativeValue)
        }
    }

    private func hexData(_ encoded: String) throws -> Data {
        let hex = encoded.hasPrefix("0x") ? String(encoded.dropFirst(2)) : encoded
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(try #require(UInt8(hex[index..<next], radix: 16)))
            index = next
        }
        return data
    }
}
