import Foundation

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

/// One ordered field in a record parameter type.
public struct ParamField: Equatable, Sendable {
    /// The field name declared by the schema.
    public let name: String

    /// The recursively interpreted field type.
    public let type: ParamType

    /// Creates an ordered record field.
    public init(name: String, type: ParamType) {
        self.name = name
        self.type = type
    }
}

/// One ordered case in an externally tagged variant parameter type.
public struct ParamCase: Equatable, Sendable {
    /// The external case tag.
    public let name: String

    /// The record-shaped fields carried by the case.
    public let fields: ParamType

    /// Creates an ordered variant case.
    public init(name: String, fields: ParamType) {
        self.name = name
        self.fields = fields
    }
}

/// The complete parameter-type model derived from a TII JSON Schema node.
///
/// Compound cases retain their nested types. Unsupported schemas are preserved as
/// ``unknown(_:)`` values instead of being rejected or guessed.
public indirect enum ParamType: Equatable, Sendable {
    /// The JSON `null` unit type.
    case unit
    /// A Boolean.
    case boolean
    /// An integer.
    case integer
    /// A byte string.
    case bytes
    /// A Cardano address.
    case address
    /// A transaction-output reference.
    case utxoRef
    /// A resolved transaction output.
    case utxo
    /// An arbitrary asset identifier.
    case anyAsset
    /// A homogeneous list and its element type.
    case list(ParamType)
    /// A positional tuple and its element types.
    case tuple([ParamType])
    /// A string-keyed map and its value type.
    case map(ParamType)
    /// A record whose fields follow the schema's `required` order.
    case record([ParamField])
    /// An externally tagged union whose cases follow `oneOf` order.
    case variant([ParamCase])
    /// A component reference retained when resolving it would recurse.
    case namedReference(String)
    /// An unsupported shape together with its original JSON schema.
    case unknown(JSONValue)

    /// Interprets a JSON Schema node without throwing.
    ///
    /// - Parameters:
    ///   - schema: The schema node to interpret.
    ///   - components: The TII `components.schemas` table used for named references.
    /// - Returns: A known parameter type, or ``unknown(_:)`` with the untouched schema.
    public static func fromJSONSchema(
        _ schema: JSONValue,
        components: [String: JSONValue] = [:]
    ) -> ParamType {
        interpret(schema, components: components, resolving: [])
    }

    private static func interpret(
        _ schema: JSONValue,
        components: [String: JSONValue],
        resolving: Set<String>
    ) -> ParamType {
        guard let object = schema.objectValue else { return .unknown(schema) }

        if let reference = object["$ref"]?.stringValue {
            let prefix = "#/components/schemas/"
            if reference.hasPrefix(prefix) {
                let name = String(reference.dropFirst(prefix.count))
                guard !resolving.contains(name) else { return .namedReference(name) }
                guard let resolved = components[name] else { return .unknown(schema) }
                return interpret(
                    resolved,
                    components: components,
                    resolving: resolving.union([name])
                )
            }

            switch reference.split(whereSeparator: { $0 == "#" || $0 == "/" }).last {
            case "Bytes": return .bytes
            case "Address": return .address
            case "UtxoRef": return .utxoRef
            case "Utxo": return .utxo
            case "AnyAsset": return .anyAsset
            default: return .unknown(schema)
            }
        }

        if let branches = object["oneOf"]?.arrayValue {
            return .variant(
                branches.map { branch in
                    guard let branchObject = branch.objectValue,
                        let name = branchObject["required"]?.arrayValue?.first?.stringValue,
                        let fields = branchObject["properties"]?.objectValue?[name]
                    else {
                        return ParamCase(name: "", fields: .unknown(branch))
                    }
                    return ParamCase(
                        name: name,
                        fields: interpret(fields, components: components, resolving: resolving)
                    )
                }
            )
        }

        switch object["type"]?.stringValue {
        case "null": return .unit
        case "boolean": return .boolean
        case "integer": return .integer
        case "array":
            if let items = object["prefixItems"]?.arrayValue {
                return .tuple(
                    items.map { interpret($0, components: components, resolving: resolving) }
                )
            }
            if let item = object["items"], item.objectValue != nil {
                return .list(interpret(item, components: components, resolving: resolving))
            }
            return .unknown(schema)
        case "object":
            if let values = object["additionalProperties"], values.objectValue != nil {
                return .map(interpret(values, components: components, resolving: resolving))
            }
            guard let properties = object["properties"]?.objectValue else {
                return .unknown(schema)
            }
            let fields = (object["required"]?.arrayValue ?? []).compactMap { item -> ParamField? in
                guard let name = item.stringValue, let field = properties[name] else { return nil }
                return ParamField(
                    name: name,
                    type: interpret(field, components: components, resolving: resolving)
                )
            }
            return .record(fields)
        default:
            return .unknown(schema)
        }
    }
}
