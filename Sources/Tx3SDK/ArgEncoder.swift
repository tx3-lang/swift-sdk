import BigInt
import Foundation

/// Type-directed conversion from native Swift values to canonical transaction arguments.
///
/// The encoder performs one recursive walk over a ``ParamType``. Aggregate children are
/// represented by explicit ``ArgValue`` tags, records follow their declared field order,
/// variants use their declared case index, and maps are sorted by key for deterministic wire
/// output.
public enum ArgEncoder {
    private static let minimumInteger = -(BigInt(1) << 127)
    private static let maximumInteger = (BigInt(1) << 127) - 1

    /// Encodes a native value according to its resolved protocol parameter type.
    ///
    /// Supported native values are `BigInt`, `Int`, `Int64`, `Bool`, `Data`, ``Address``,
    /// ``UtxoRef``, arrays, and string-keyed dictionaries. Untyped, UTxO, and any-asset
    /// parameters accept ``JSONValue`` or another JSON-compatible native value unchanged.
    /// Floating-point values are never accepted as integers.
    ///
    /// - Throws: ``Tx3Error/resolution(_:)`` when the value has the wrong shape or a record or
    ///   variant does not match its declaration; ``Tx3Error/validation(_:)`` when an integer is
    ///   outside signed i128.
    public static func encode(_ value: Any, as type: ParamType) throws -> ArgValue {
        try encode(value, as: type, path: "$")
    }

    /// Looks up a transaction parameter case-insensitively and encodes its native value.
    ///
    /// - Throws: ``Tx3Error/resolution(_:)`` when the parameter is undeclared or the value does
    ///   not match its declared type.
    public static func encode(
        _ value: Any,
        for parameter: String,
        in transaction: Transaction
    ) throws -> ArgValue {
        guard let type = transaction.parameterType(named: parameter) else {
            throw Tx3Error.resolution(
                .invalidArgument(path: parameter, expected: "declared transaction parameter")
            )
        }
        return try encode(value, as: type, path: parameter)
    }

    private static func encode(_ value: Any, as type: ParamType, path: String) throws -> ArgValue {
        switch type {
        case .unit:
            guard value is Void || value is NSNull || value as? JSONValue == .null else {
                throw mismatch(path, expected: "unit")
            }
            return .structure(constructor: 0, fields: [])

        case .boolean:
            guard let value = value as? Bool else { throw mismatch(path, expected: "Bool") }
            return .boolean(value)

        case .integer:
            let integer: BigInt
            switch value {
            case let value as BigInt: integer = value
            case let value as Int: integer = BigInt(value)
            case let value as Int64: integer = BigInt(value)
            default: throw mismatch(path, expected: "BigInt, Int, or Int64")
            }
            guard integer >= minimumInteger, integer <= maximumInteger else {
                throw Tx3Error.validation(
                    .integerOutOfRange(path: path, expected: "signed i128 integer")
                )
            }
            return .integer(integer)

        case .bytes:
            guard let value = value as? Data else { throw mismatch(path, expected: "Data") }
            return .bytes(value)

        case .address:
            guard let value = value as? Address else { throw mismatch(path, expected: "Address") }
            return .address(value)

        case .utxoRef:
            guard let value = value as? UtxoRef else {
                throw mismatch(path, expected: "UtxoRef")
            }
            return .utxoRef(value)

        case .list(let element):
            guard let values = value as? [Any] else { throw mismatch(path, expected: "Array") }
            return .list(
                try values.enumerated().map { index, value in
                    try encode(value, as: element, path: "\(path)[\(index)]")
                }
            )

        case .tuple(let elements):
            guard let values = value as? [Any], values.count == elements.count else {
                throw mismatch(path, expected: "tuple with \(elements.count) elements")
            }
            return .tuple(
                try zip(values, elements).enumerated().map { index, pair in
                    try encode(pair.0, as: pair.1, path: "\(path)[\(index)]")
                }
            )

        case .map(let element):
            guard let values = value as? [String: Any] else {
                throw mismatch(path, expected: "[String: Value]")
            }
            return .mapPairs(
                try values.sorted(by: { $0.key < $1.key }).map { key, value in
                    ArgMapEntry(
                        key: .string(key),
                        value: try encode(value, as: element, path: "\(path).\(key)")
                    )
                }
            )

        case .record(let fields):
            guard let values = value as? [String: Any] else {
                throw mismatch(path, expected: "record object")
            }
            let declared = Set(fields.map(\.name))
            guard values.keys.allSatisfy(declared.contains), values.count == fields.count else {
                throw mismatch(path, expected: "record fields \(fields.map(\.name))")
            }
            let encoded = try fields.map { field -> ArgValue in
                guard let fieldValue = values[field.name] else {
                    throw mismatch("\(path).\(field.name)", expected: expected(field.type))
                }
                return try encode(
                    fieldValue,
                    as: field.type,
                    path: "\(path).\(field.name)"
                )
            }
            return .structure(constructor: 0, fields: encoded)

        case .variant(let cases):
            guard let value = value as? [String: Any], value.count == 1,
                let (name, payload) = value.first,
                let index = cases.firstIndex(where: { $0.name == name })
            else {
                throw mismatch(path, expected: "single declared variant case")
            }
            let caseType = cases[index].fields
            if case .record(let fields) = caseType {
                guard let values = payload as? [String: Any] else {
                    throw mismatch("\(path).\(name)", expected: "record object")
                }
                let declared = Set(fields.map(\.name))
                guard values.keys.allSatisfy(declared.contains), values.count == fields.count else {
                    throw mismatch(
                        "\(path).\(name)",
                        expected: "record fields \(fields.map(\.name))"
                    )
                }
                let encoded = try fields.map { field -> ArgValue in
                    guard let fieldValue = values[field.name] else {
                        throw mismatch(
                            "\(path).\(name).\(field.name)",
                            expected: expected(field.type)
                        )
                    }
                    return try encode(
                        fieldValue,
                        as: field.type,
                        path: "\(path).\(name).\(field.name)"
                    )
                }
                return .structure(constructor: UInt(index), fields: encoded)
            }
            return .structure(
                constructor: UInt(index),
                fields: [try encode(payload, as: caseType, path: "\(path).\(name)")]
            )

        case .utxo, .anyAsset, .unknown:
            return .json(try jsonValue(from: value, path: path))

        case .namedReference(let name):
            throw mismatch(path, expected: "resolved named type \(name)")
        }
    }

    private static func jsonValue(from value: Any, path: String) throws -> JSONValue {
        switch value {
        case let value as JSONValue: return value
        case is NSNull: return .null
        case let value as Bool: return .boolean(value)
        case let value as String: return .string(value)
        case let value as Int:
            guard let number = Double(exactly: value) else {
                throw mismatch(path, expected: "JSON integer exactly representable as Double")
            }
            return .number(number)
        case let value as Int64:
            guard let number = Double(exactly: value) else {
                throw mismatch(path, expected: "JSON integer exactly representable as Double")
            }
            return .number(number)
        case let value as Double where value.isFinite: return .number(value)
        case let value as [Any]:
            return .array(
                try value.enumerated().map { index, item in
                    try jsonValue(from: item, path: "\(path)[\(index)]")
                }
            )
        case let value as [String: Any]:
            return .object(
                try Dictionary(
                    uniqueKeysWithValues: value.map { key, item in
                        (key, try jsonValue(from: item, path: "\(path).\(key)"))
                    }
                )
            )
        default: throw mismatch(path, expected: "JSON-compatible value")
        }
    }

    private static func mismatch(_ path: String, expected: String) -> Tx3Error {
        .resolution(.invalidArgument(path: path, expected: expected))
    }

    private static func expected(_ type: ParamType) -> String {
        switch type {
        case .unit: "unit"
        case .boolean: "Bool"
        case .integer: "BigInt, Int, or Int64"
        case .bytes: "Data"
        case .address: "Address"
        case .utxoRef: "UtxoRef"
        case .utxo, .anyAsset, .unknown: "JSON-compatible value"
        case .list: "Array"
        case .tuple(let elements): "tuple with \(elements.count) elements"
        case .map: "[String: Value]"
        case .record(let fields): "record fields \(fields.map(\.name))"
        case .variant: "single declared variant case"
        case .namedReference(let name): "resolved named type \(name)"
        }
    }
}

extension Transaction {
    /// Returns a declared parameter type using a case-insensitive name match.
    public func parameterType(named name: String) -> ParamType? {
        if let exact = parameters[name] { return exact }
        return parameters.first { declared, _ in
            declared.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}
