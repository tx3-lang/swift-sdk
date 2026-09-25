import Foundation

/// One transaction declared by a loaded TII document.
public struct Transaction: Equatable, Sendable {
    /// The untouched TIR envelope consumed by transaction resolution.
    public let tir: JSONValue

    /// The untouched JSON Schema for this transaction's parameters.
    public let parameterSchema: JSONValue

    /// Parameter types indexed by their declared names.
    public let parameters: [String: ParamType]

    /// Required parameter names in declaration order.
    public let requiredParameters: [String]
}

/// An in-memory canonical Transaction Invoke Interface document.
public struct Protocol: Equatable, Sendable {
    /// The protocol's named transaction definitions.
    public let transactions: [String: Transaction]

    /// Declared party names and their untouched definitions.
    public let parties: [String: JSONValue]

    /// Named profiles and their untouched definitions.
    public let profiles: [String: JSONValue]

    /// The untouched protocol-level environment schema, when present.
    public let environment: JSONValue?

    /// Environment parameter types indexed by their declared names.
    public let environmentParameters: [String: ParamType]

    /// Named component schemas used by transaction and environment parameters.
    public let componentSchemas: [String: JSONValue]

    /// The complete parsed TII document, retained without schema loss.
    public let rawValue: JSONValue

    /// Loads a TII document from a file URL.
    ///
    /// - Throws: ``Tx3Error/protocolError(_:)`` with an unreadable-file, invalid-JSON,
    ///   or invalid-schema failure. Error context never includes document values.
    public static func fromFile(_ url: URL) throws -> Protocol {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Tx3Error.protocolError(.unreadable(path: url.path))
        }
        return try fromJSON(data)
    }

    /// Loads a TII document from UTF-8 JSON bytes.
    ///
    /// - Throws: ``Tx3Error/protocolError(_:)`` when JSON decoding or TII validation fails.
    public static func fromJSON(_ data: Data) throws -> Protocol {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch let error as DecodingError {
            throw Tx3Error.protocolError(.invalidJSON(context: decodingContext(error)))
        } catch {
            throw Tx3Error.protocolError(.invalidJSON(context: "JSON document"))
        }
        return try fromJSON(value)
    }

    /// Loads a TII document from a JSON string.
    ///
    /// - Throws: ``Tx3Error/protocolError(_:)`` when JSON decoding or TII validation fails.
    public static func fromJSON(_ string: String) throws -> Protocol {
        try fromJSON(Data(string.utf8))
    }

    /// Loads a TII document from an already parsed JSON value.
    ///
    /// - Throws: ``Tx3Error/protocolError(_:)`` when required TII structure is absent.
    public static func fromJSON(_ value: JSONValue) throws -> Protocol {
        guard let root = value.objectValue else { throw invalidSchema("$") }
        let parties = try object(at: "parties", in: root)
        let profiles = try object(at: "profiles", in: root)
        let rawTransactions = try object(at: "transactions", in: root)
        _ = try object(at: "tii", in: root)
        _ = try object(at: "protocol", in: root)

        let components: [String: JSONValue]
        if let rawComponents = root["components"] {
            guard let componentObject = rawComponents.objectValue else {
                throw invalidSchema("$.components")
            }
            if let rawSchemas = componentObject["schemas"] {
                guard let schemas = rawSchemas.objectValue else {
                    throw invalidSchema("$.components.schemas")
                }
                components = schemas
            } else {
                components = [:]
            }
        } else {
            components = [:]
        }

        let environment: JSONValue?
        let environmentParameters: [String: ParamType]
        if let rawEnvironment = root["environment"] {
            guard rawEnvironment.objectValue != nil else {
                throw invalidSchema("$.environment")
            }
            environment = rawEnvironment
            environmentParameters = parameterTypes(
                from: rawEnvironment,
                components: components
            )
        } else {
            environment = nil
            environmentParameters = [:]
        }

        var transactions: [String: Transaction] = [:]
        transactions.reserveCapacity(rawTransactions.count)
        for (name, rawTransaction) in rawTransactions {
            guard let transactionObject = rawTransaction.objectValue else {
                throw invalidSchema("$.transactions.\(name)")
            }
            guard let tir = transactionObject["tir"], tir.objectValue != nil else {
                throw invalidSchema("$.transactions.\(name).tir")
            }
            guard
                let tirData = try? JSONEncoder().encode(tir),
                (try? JSONDecoder().decode(TIREnvelope.self, from: tirData)) != nil
            else {
                throw invalidSchema("$.transactions.\(name).tir")
            }
            guard let params = transactionObject["params"], params.objectValue != nil else {
                throw invalidSchema("$.transactions.\(name).params")
            }
            let required =
                params.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            transactions[name] = Transaction(
                tir: tir,
                parameterSchema: params,
                parameters: parameterTypes(from: params, components: components),
                requiredParameters: required
            )
        }

        return Protocol(
            transactions: transactions,
            parties: parties,
            profiles: profiles,
            environment: environment,
            environmentParameters: environmentParameters,
            componentSchemas: components,
            rawValue: value
        )
    }

    /// Returns a fresh value-semantic client builder seeded by this protocol.
    ///
    /// This is the only dynamic bridge from TII loading into the facade API.
    public func client() -> Tx3ClientBuilder {
        Tx3ClientBuilder(protocol: self)
    }

    private static func object(
        at key: String,
        in root: [String: JSONValue]
    ) throws -> [String: JSONValue] {
        guard let object = root[key]?.objectValue else { throw invalidSchema("$.\(key)") }
        return object
    }

    private static func parameterTypes(
        from schema: JSONValue,
        components: [String: JSONValue]
    ) -> [String: ParamType] {
        guard let properties = schema.objectValue?["properties"]?.objectValue else { return [:] }
        return properties.mapValues { ParamType.fromJSONSchema($0, components: components) }
    }

    private static func invalidSchema(_ path: String) -> Tx3Error {
        .protocolError(.invalidSchema(context: path))
    }

    private static func decodingContext(_ error: DecodingError) -> String {
        let codingPath: [any CodingKey]
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context),
            .typeMismatch(_, let context), .valueNotFound(_, let context):
            codingPath = context.codingPath
        @unknown default:
            return "JSON document"
        }
        let path = codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "JSON document" : "$.\(path)"
    }
}
