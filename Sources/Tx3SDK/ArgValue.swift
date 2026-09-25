import BigInt
import Foundation

/// One entry in an explicitly tagged map argument.
public struct ArgMapEntry: Codable, Equatable, Sendable {
    /// The tagged map key.
    public let key: ArgValue

    /// The tagged map value.
    public let value: ArgValue

    /// Creates a tagged map entry.
    public init(key: ArgValue, value: ArgValue) {
        self.key = key
        self.value = value
    }

    /// Decodes the canonical two-element tagged pair.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        key = try container.decode(ArgValue.self)
        value = try container.decode(ArgValue.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A tagged map entry must contain exactly two values"
            )
        }
    }

    /// Encodes the canonical two-element tagged pair.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(key)
        try container.encode(value)
    }
}

/// A JSON-compatible value used when the protocol schema cannot provide a stronger type.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    /// The JSON null value.
    case null
    /// A JSON Boolean.
    case boolean(Bool)
    /// A finite JSON number.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object.
    case object([String: JSONValue])

    /// Decodes one JSON-compatible value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// Encodes one JSON-compatible value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A canonical, explicitly tagged transaction argument.
///
/// Aggregate values recursively contain tagged children so generated and dynamic clients can
/// produce the same TRP representation without embedding a protocol schema.
public indirect enum ArgValue: Codable, Equatable, Sendable {
    /// An arbitrary-precision integer.
    case integer(BigInt)
    /// A Boolean value.
    case boolean(Bool)
    /// A string value, including tagged map keys.
    case string(String)
    /// Raw bytes.
    case bytes(Data)
    /// A validated address.
    case address(Address)
    /// A transaction-output reference.
    case utxoRef(UtxoRef)
    /// A homogeneous list.
    case list([ArgValue])
    /// A positional tuple.
    case tuple([ArgValue])
    /// An ordered sequence of map entries.
    case mapPairs([ArgMapEntry])
    /// A record or variant encoded by constructor index and ordered fields.
    case structure(constructor: UInt, fields: [ArgValue])
    /// A passthrough value for unknown, UTxO, and any-asset schemas.
    case json(JSONValue)

    /// Promotes a platform integer losslessly.
    public static func integer(_ value: Int) -> Self { .integer(BigInt(value)) }

    /// Promotes a signed 64-bit integer losslessly.
    public static func integer(_ value: Int64) -> Self { .integer(BigInt(value)) }

    private enum CodingKeys: String, CodingKey {
        case address, bool, bytes, int, list, map, string, `struct`, tuple, utxoRef
    }

    private struct StructureValue: Codable {
        let constructor: UInt
        let fields: [ArgValue]
    }

    private static func decodeHex(
        _ encoded: String, forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Data {
        let hex = encoded.hasPrefix("0x") ? String(encoded.dropFirst(2)) : encoded
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "The tagged bytes value is not an even-length hexadecimal string"
            )
        }

        var bytes = Data()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "The tagged bytes value contains invalid hexadecimal digits"
                )
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func encodeHex(_ bytes: Data, prefixed: Bool) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return prefixed ? "0x" + hex : hex
    }

    /// Decodes the canonical single-key tagged representation.
    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .json(try JSONValue(from: decoder))
            return
        }
        let keys = container.allKeys
        guard keys.count == 1, let key = keys.first else {
            self = .json(try JSONValue(from: decoder))
            return
        }
        switch key {
        case .int:
            if let encoded = try? container.decode(String.self, forKey: key) {
                let value: BigInt?
                if encoded.hasPrefix("0x") {
                    value = BigInt(encoded.dropFirst(2), radix: 16)
                } else {
                    value = BigInt(encoded)
                }
                guard let value else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key,
                        in: container,
                        debugDescription:
                            "The tagged integer is not a decimal or hexadecimal BigInt"
                    )
                }
                self = .integer(value)
            } else if let value = try? container.decode(Int64.self, forKey: key) {
                self = .integer(BigInt(value))
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "The tagged integer is not an exact JSON integer"
                )
            }
        case .bool: self = .boolean(try container.decode(Bool.self, forKey: key))
        case .string: self = .string(try container.decode(String.self, forKey: key))
        case .bytes:
            let encoded = try container.decode(String.self, forKey: key)
            self = .bytes(try Self.decodeHex(encoded, forKey: key, in: container))
        case .address: self = .address(try container.decode(Address.self, forKey: key))
        case .utxoRef:
            let encoded = try container.decode(String.self, forKey: key)
            let parts = encoded.split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 2, let index = UInt32(parts[1]) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "The tagged UTxO reference must use txid#index format"
                )
            }
            let txId = try Self.decodeHex(String(parts[0]), forKey: key, in: container)
            self = .utxoRef(UtxoRef(txId: txId, index: index))
        case .list: self = .list(try container.decode([ArgValue].self, forKey: key))
        case .tuple: self = .tuple(try container.decode([ArgValue].self, forKey: key))
        case .map: self = .mapPairs(try container.decode([ArgMapEntry].self, forKey: key))
        case .struct:
            let value = try container.decode(StructureValue.self, forKey: key)
            self = .structure(constructor: value.constructor, fields: value.fields)
        }
    }

    /// Encodes the canonical single-key tagged representation.
    public func encode(to encoder: any Encoder) throws {
        if case .json(let value) = self {
            try value.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integer(let value):
            if let exact = Int64(String(value)) {
                try container.encode(exact, forKey: .int)
            } else {
                try container.encode(String(value), forKey: .int)
            }
        case .boolean(let value): try container.encode(value, forKey: .bool)
        case .string(let value): try container.encode(value, forKey: .string)
        case .bytes(let value):
            try container.encode(Self.encodeHex(value, prefixed: true), forKey: .bytes)
        case .address(let value): try container.encode(value, forKey: .address)
        case .utxoRef(let value):
            let encoded = "\(Self.encodeHex(value.txId, prefixed: false))#\(value.index)"
            try container.encode(encoded, forKey: .utxoRef)
        case .list(let value): try container.encode(value, forKey: .list)
        case .tuple(let value): try container.encode(value, forKey: .tuple)
        case .mapPairs(let value): try container.encode(value, forKey: .map)
        case .structure(let constructor, let fields):
            try container.encode(
                StructureValue(constructor: constructor, fields: fields),
                forKey: .struct
            )
        case .json: break
        }
    }
}
