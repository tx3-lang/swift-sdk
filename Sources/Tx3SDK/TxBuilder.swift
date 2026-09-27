import Foundation

/// A protocol profile's environment values and party-address defaults.
public struct Profile: Equatable, Sendable {
    /// Environment values supplied to each resolve request.
    public let environment: [String: JSONValue]

    /// Default party addresses keyed by declared party name.
    public let parties: [String: String]

    /// Creates a profile from its deconstructed runtime values.
    public init(
        environment: [String: JSONValue] = [:],
        parties: [String: String] = [:]
    ) {
        self.environment = environment
        self.parties = parties
    }
}

/// A protocol party represented by a read-only address or an address-aware signer.
public enum Party: Sendable {
    /// A party that contributes an address without signing.
    case address(Address)
    /// A party whose address is read from its signer.
    case signer(any Signer)

    var addressValue: Address {
        switch self {
        case .address(let address): address
        case .signer(let signer): signer.address()
        }
    }
}

/// A value-semantic builder for the high-level Tx3 client.
///
/// Obtain a dynamic builder through ``Protocol/client()`` or seed generated bindings through
/// ``fromParts(transactions:profiles:knownParties:)``. Configuration setters are infallible;
/// ``build()`` performs name and endpoint validation.
public struct Tx3ClientBuilder: Sendable {
    private var transactions: [String: TIREnvelope]
    private var parameters: [String: [String: ParamType]]
    private var requiredParameters: [String: [String]]
    private var profiles: [String: Profile]
    private var knownParties: Set<String>
    private var options: ClientOptions?
    private var headers: [String: String]
    private var selectedProfileName: String?
    private var parties: [String: Party]
    private var partyOrder: [String]
    private var partyNamesRequiringValidation: Set<String>
    private var environmentOverrides: [String: JSONValue]
    private var transport: (any HTTPTransport)?

    /// Seeds a builder with the runtime fragments embedded by generated clients.
    ///
    /// Parts-seeded transactions intentionally carry no TII schema or ``ParamType`` metadata.
    /// Generated methods provide their canonical values through ``TxBuilder/argTagged(_:_:)``.
    public static func fromParts(
        transactions: [String: TIREnvelope],
        profiles: [String: Profile],
        knownParties: Set<String>
    ) -> Tx3ClientBuilder {
        Tx3ClientBuilder(
            transactions: transactions,
            parameters: [:],
            requiredParameters: [:],
            profiles: profiles,
            knownParties: Set(knownParties.map { $0.lowercased() })
        )
    }

    init(protocol protocolValue: Protocol) {
        var envelopes: [String: TIREnvelope] = [:]
        var parameters: [String: [String: ParamType]] = [:]
        var required: [String: [String]] = [:]
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for (name, transaction) in protocolValue.transactions {
            if let data = try? encoder.encode(transaction.tir),
                let envelope = try? decoder.decode(TIREnvelope.self, from: data)
            {
                envelopes[name] = envelope
            }
            parameters[name] = transaction.parameters
            required[name] = transaction.requiredParameters
        }

        self.init(
            transactions: envelopes,
            parameters: parameters,
            requiredParameters: required,
            profiles: protocolValue.profiles.mapValues { value in
                guard let object = value.objectValue else { return Profile() }
                let environment = object["environment"]?.objectValue ?? [:]
                let parties = object["parties"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
                return Profile(environment: environment, parties: parties)
            },
            knownParties: Set(protocolValue.parties.keys.map { $0.lowercased() })
        )
    }

    private init(
        transactions: [String: TIREnvelope],
        parameters: [String: [String: ParamType]],
        requiredParameters: [String: [String]],
        profiles: [String: Profile],
        knownParties: Set<String>
    ) {
        self.transactions = transactions
        self.parameters = parameters
        self.requiredParameters = requiredParameters
        self.profiles = profiles
        self.knownParties = knownParties
        options = nil
        headers = [:]
        selectedProfileName = nil
        parties = [:]
        partyOrder = []
        partyNamesRequiringValidation = []
        environmentOverrides = [:]
        transport = nil
    }

    /// Sets the complete TRP configuration.
    public func trp(_ options: ClientOptions) -> Tx3ClientBuilder {
        var copy = self
        copy.options = options
        return copy
    }

    /// Sets endpoint-only TRP configuration, replacing previously supplied options.
    public func trpEndpoint(_ url: URL) -> Tx3ClientBuilder {
        trp(ClientOptions(endpoint: url))
    }

    /// Selects a named protocol profile. Validation is deferred to ``build()``.
    public func withProfile(_ name: String) -> Tx3ClientBuilder {
        var copy = self
        copy.selectedProfileName = name
        return copy
    }

    /// Binds a declared party. Validation is deferred to ``build()``.
    public func withParty(_ name: String, _ party: Party) -> Tx3ClientBuilder {
        var copy = self
        let normalized = name.lowercased()
        if copy.parties[normalized] == nil {
            copy.partyOrder.append(normalized)
        }
        copy.parties[normalized] = party
        copy.partyNamesRequiringValidation.insert(normalized)
        return copy
    }

    /// Binds multiple declared parties. Later case-insensitive names replace earlier values.
    public func withParties(_ parties: [String: Party]) -> Tx3ClientBuilder {
        parties.reduce(self) { builder, entry in
            builder.withParty(entry.key, entry.value)
        }
    }

    /// Binds a party without checking the name against the declared-party set.
    ///
    /// This is the generated-client entry point; dynamic consumers should use ``withParty(_:_:)``.
    public func withPartyUnchecked(_ name: String, _ party: Party) -> Tx3ClientBuilder {
        var copy = self
        let normalized = name.lowercased()
        if copy.parties[normalized] == nil {
            copy.partyOrder.append(normalized)
        }
        copy.parties[normalized] = party
        copy.partyNamesRequiringValidation.remove(normalized)
        return copy
    }

    /// Adds or replaces one HTTP header. Explicit header setters override option headers.
    public func withHeader(_ name: String, _ value: String) -> Tx3ClientBuilder {
        var copy = self
        copy.headers[name] = value
        return copy
    }

    /// Adds or replaces one resolver-environment override.
    public func withEnvValue(_ name: String, _ value: JSONValue) -> Tx3ClientBuilder {
        var copy = self
        copy.environmentOverrides[name] = value
        return copy
    }

    func withTransport(_ transport: any HTTPTransport) -> Tx3ClientBuilder {
        var copy = self
        copy.transport = transport
        return copy
    }

    /// Validates configuration and creates the sole high-level client type.
    ///
    /// - Throws: ``Tx3Error/construction(_:)`` when no endpoint was configured,
    ///   ``Tx3Error/unknownProfile(_:)`` for an unknown selected profile, or
    ///   ``Tx3Error/unknownParty(_:)`` for an unknown validated party binding.
    public func build() throws -> Tx3Client {
        guard let options else {
            throw Tx3Error.construction(.missingTrpEndpoint)
        }
        let selectedProfile: Profile?
        if let selectedProfileName {
            guard let profile = profiles[selectedProfileName] else {
                throw Tx3Error.unknownProfile(selectedProfileName)
            }
            selectedProfile = profile
        } else {
            selectedProfile = nil
        }
        if let unknown = partyNamesRequiringValidation.sorted().first(where: {
            !knownParties.contains($0)
        }) {
            throw Tx3Error.unknownParty(unknown)
        }

        var finalHeaders = options.headers
        for (name, value) in headers {
            finalHeaders[name] = value
        }
        let finalOptions = ClientOptions(
            endpoint: options.endpoint,
            headers: finalHeaders,
            timeout: options.timeout
        )
        var profileParties: [String: Party] = [:]
        for (name, value) in selectedProfile?.parties ?? [:] {
            profileParties[name.lowercased()] = .address(try Address(value))
        }

        let trp =
            transport.map { TRPClient(options: finalOptions, transport: $0) }
            ?? TRPClient(options: finalOptions)
        return Tx3Client(
            transactions: transactions,
            parameters: parameters,
            requiredParameters: requiredParameters,
            knownParties: knownParties,
            trp: trp,
            parties: parties,
            partyOrder: partyOrder,
            profileEnvironment: selectedProfile?.environment ?? [:],
            profileParties: profileParties,
            environmentOverrides: environmentOverrides
        )
    }
}

/// The single high-level client used by both dynamic and generated consumers.
public struct Tx3Client: Sendable {
    private let transactions: [String: TIREnvelope]
    private let parameters: [String: [String: ParamType]]
    private let requiredParameters: [String: [String]]
    private let knownParties: Set<String>
    private let trp: TRPClient
    private var parties: [String: Party]
    private var partyOrder: [String]
    private let profileEnvironment: [String: JSONValue]
    private let profileParties: [String: Party]
    private let environmentOverrides: [String: JSONValue]

    fileprivate init(
        transactions: [String: TIREnvelope],
        parameters: [String: [String: ParamType]],
        requiredParameters: [String: [String]],
        knownParties: Set<String>,
        trp: TRPClient,
        parties: [String: Party],
        partyOrder: [String],
        profileEnvironment: [String: JSONValue],
        profileParties: [String: Party],
        environmentOverrides: [String: JSONValue]
    ) {
        self.transactions = transactions
        self.parameters = parameters
        self.requiredParameters = requiredParameters
        self.knownParties = knownParties
        self.trp = trp
        self.parties = parties
        self.partyOrder = partyOrder
        self.profileEnvironment = profileEnvironment
        self.profileParties = profileParties
        self.environmentOverrides = environmentOverrides
    }

    /// Binds a party after construction and validates its name immediately.
    ///
    /// - Throws: ``Tx3Error/unknownParty(_:)`` when `name` is not declared.
    public func withParty(_ name: String, _ party: Party) throws -> Tx3Client {
        let normalized = name.lowercased()
        guard knownParties.contains(normalized) else { throw Tx3Error.unknownParty(normalized) }
        return withPartyUnchecked(normalized, party)
    }

    /// Binds multiple parties after construction, validating each name immediately.
    public func withParties(_ parties: [String: Party]) throws -> Tx3Client {
        try parties.reduce(self) { client, entry in
            try client.withParty(entry.key, entry.value)
        }
    }

    /// Binds a party without validating its name, for generated wrappers with baked-in names.
    public func withPartyUnchecked(_ name: String, _ party: Party) -> Tx3Client {
        var copy = self
        let normalized = name.lowercased()
        if copy.parties[normalized] == nil {
            copy.partyOrder.append(normalized)
        }
        copy.parties[normalized] = party
        return copy
    }

    /// Starts a transaction invocation.
    ///
    /// - Throws: ``Tx3Error/unknownTx(_:)`` when `name` is not declared.
    public func tx(_ name: String) throws -> TxBuilder {
        guard let tir = transactions[name] else { throw Tx3Error.unknownTx(name) }
        var environment = profileEnvironment
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        var mergedParties = profileParties
        for (name, party) in parties {
            mergedParties[name] = party
        }
        return TxBuilder(
            tir: tir,
            environment: environment,
            parties: mergedParties,
            signerOrder: partyOrder,
            parameters: parameters[name],
            requiredParameters: requiredParameters[name] ?? [],
            trp: trp
        )
    }
}

/// A value-semantic transaction builder containing all inputs required for resolution.
public struct TxBuilder: Sendable {
    private let tir: TIREnvelope?
    private let environment: [String: JSONValue]
    private let parties: [String: Party]
    private let signerOrder: [String]
    private let parameters: [String: ParamType]?
    private let requiredParameters: [String]
    private let trp: TRPClient?
    var taggedArguments: [String: ArgValue]

    init(
        tir: TIREnvelope,
        environment: [String: JSONValue],
        parties: [String: Party],
        signerOrder: [String],
        parameters: [String: ParamType]?,
        requiredParameters: [String],
        trp: TRPClient
    ) {
        self.tir = tir
        self.environment = environment
        self.parties = parties
        self.signerOrder = signerOrder
        self.parameters = parameters
        self.requiredParameters = requiredParameters
        self.trp = trp
        taggedArguments = [:]
    }

    init(taggedArguments: [String: ArgValue] = [:]) {
        tir = nil
        environment = [:]
        parties = [:]
        signerOrder = []
        parameters = nil
        requiredParameters = []
        trp = nil
        self.taggedArguments = taggedArguments
    }

    /// Encodes and adds one native value using the dynamic transaction's resolved parameter type.
    ///
    /// - Throws: ``Tx3Error/resolution(_:)`` when the parameter is unavailable or the native
    ///   value does not match its declared type. Parts-seeded generated clients use
    ///   ``argTagged(_:_:)`` instead.
    public func arg(_ name: String, _ value: Any) throws -> TxBuilder {
        guard let parameters,
            let declared = parameters.first(where: { $0.key.lowercased() == name.lowercased() })
        else {
            throw Tx3Error.resolution(
                .invalidArgument(path: name, expected: "declared transaction parameter")
            )
        }
        return argTagged(name, try ArgEncoder.encode(value, as: declared.value))
    }

    /// Encodes and adds native values in iteration order; later case-insensitive writes win.
    public func args(_ values: [String: Any]) throws -> TxBuilder {
        try values.reduce(self) { builder, entry in
            try builder.arg(entry.key, entry.value)
        }
    }

    /// Adds an already canonical tagged argument without another schema-directed encoding pass.
    public func argTagged(_ name: String, _ value: ArgValue) -> TxBuilder {
        var copy = self
        copy.taggedArguments[name.lowercased()] = value
        return copy
    }

    /// Resolves this invocation through the configured TRP client.
    ///
    /// Party addresses are injected first; explicit arguments override them. Required arguments
    /// are checked before any transport call.
    ///
    /// - Throws: ``Tx3Error/resolution(_:)`` for missing required arguments, or a typed transport
    ///   failure from the TRP client.
    public func resolve() async throws -> ResolvedTx {
        guard let tir, let trp else {
            throw Tx3Error.resolution(
                .invalidArgument(path: "$", expected: "transaction seeded by Tx3Client.tx")
            )
        }
        var arguments = Dictionary(
            uniqueKeysWithValues: parties.map { name, party in
                (name.lowercased(), ArgValue.address(party.addressValue))
            }
        )
        for (name, value) in taggedArguments {
            arguments[name] = value
        }
        for required in requiredParameters where arguments[required.lowercased()] == nil {
            throw Tx3Error.resolution(.missingParameter(name: required))
        }
        let response = try await trp.resolve(
            ResolveParams(
                tir: tir,
                args: arguments,
                env: environment.isEmpty ? nil : environment
            )
        )
        let signers = signerOrder.compactMap { name -> TransactionSigner? in
            guard case .signer(let signer) = parties[name] else { return nil }
            return TransactionSigner(name: name, address: signer.address(), signer: signer)
        }
        return ResolvedTx(
            trp: trp,
            hash: response.hash,
            txHex: response.tx,
            signers: signers
        )
    }
}

/// A transaction resolved to a hash and hexadecimal CBOR bytes.
///
/// Signing and submission behavior is layered onto this value by the transaction-lifecycle API.
public struct ResolvedTx: Sendable {
    /// The resolver-produced transaction hash.
    public let hash: String

    /// The resolver-produced hexadecimal transaction CBOR.
    public let txHex: String

    let trp: TRPClient?
    let signers: [TransactionSigner]
    let manualWitnesses: [TxWitness]

    init(
        trp: TRPClient? = nil,
        hash: String,
        txHex: String,
        signers: [TransactionSigner] = [],
        manualWitnesses: [TxWitness] = []
    ) {
        self.trp = trp
        self.hash = hash
        self.txHex = txHex
        self.signers = signers
        self.manualWitnesses = manualWitnesses
    }
}

extension ResolvedTx: Equatable {
    /// Compares resolved transactions by their public hash and CBOR bytes.
    public static func == (lhs: ResolvedTx, rhs: ResolvedTx) -> Bool {
        lhs.hash == rhs.hash && lhs.txHex == rhs.txHex
    }
}
