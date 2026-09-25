import Foundation

/// The wire encoding used by an embedded TIR document.
public enum TIREncoding: String, Codable, Sendable {
    /// Hexadecimal bytes.
    case hex
    /// Base64-encoded bytes.
    case base64
}

/// A TIR document sent to `trp.resolve`.
public struct TIREnvelope: Codable, Equatable, Sendable {
    /// The encoding of ``content``.
    public let encoding: TIREncoding
    /// The encoded TIR bytes.
    public let content: String
    /// The encoded TIR version.
    public let version: String

    /// Creates a TIR envelope.
    public init(encoding: TIREncoding, content: String, version: String) {
        self.encoding = encoding
        self.content = content
        self.version = version
    }
}

/// Encoded bytes carried by TRP.
public struct BytesEnvelope: Codable, Equatable, Sendable {
    /// The encoded byte content.
    public let content: String
    /// The MIME type or format identifier for the content.
    public let contentType: String

    /// Creates a byte envelope.
    public init(content: String, contentType: String) {
        self.content = content
        self.contentType = contentType
    }
}

/// Parameters for `trp.resolve`.
public struct ResolveParams: Codable, Equatable, Sendable {
    /// The TIR program to resolve.
    public let tir: TIREnvelope
    /// Transaction arguments keyed by their declared parameter names.
    public let args: [String: ArgValue]
    /// Optional resolver environment values.
    public let env: [String: JSONValue]?

    /// Creates resolve parameters.
    public init(
        tir: TIREnvelope,
        args: [String: ArgValue],
        env: [String: JSONValue]? = nil
    ) {
        self.tir = tir
        self.args = args
        self.env = env
    }
}

/// The resolved transaction returned by `trp.resolve`.
public struct ResolveResponse: Codable, Equatable, Sendable {
    /// The transaction hash.
    public let hash: String
    /// Hexadecimal transaction bytes.
    public let tx: String

    /// Creates a resolved transaction response.
    public init(hash: String, tx: String) {
        self.hash = hash
        self.tx = tx
    }
}

/// A cryptographic signature sent as a transaction witness.
public struct TxSignature: Codable, Equatable, Sendable {
    /// The verification key bytes.
    public let key: BytesEnvelope
    /// The signature bytes.
    public let signature: BytesEnvelope
    /// The server-defined signature type.
    public let type: String

    /// Creates a transaction signature.
    public init(key: BytesEnvelope, signature: BytesEnvelope, type: String) {
        self.key = key
        self.signature = signature
        self.type = type
    }
}

/// A signature or opaque byte envelope sent to `trp.submit`.
public enum TxWitness: Codable, Equatable, Sendable {
    /// A structured key and signature witness.
    case signature(TxSignature)
    /// An opaque witness understood by the TRP server.
    case bytes(BytesEnvelope)

    /// Decodes either wire shape admitted by the pinned TRP schema.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let signature = try? container.decode(TxSignature.self) {
            self = .signature(signature)
        } else {
            self = .bytes(try container.decode(BytesEnvelope.self))
        }
    }

    /// Encodes the selected witness using its untagged TRP wire shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .signature(let value): try container.encode(value)
        case .bytes(let value): try container.encode(value)
        }
    }
}

/// Parameters for `trp.submit`.
public struct SubmitParams: Codable, Equatable, Sendable {
    /// The resolved transaction bytes.
    public let tx: BytesEnvelope
    /// The witnesses authorizing the transaction.
    public let witnesses: [TxWitness]

    /// Creates submit parameters.
    public init(tx: BytesEnvelope, witnesses: [TxWitness]) {
        self.tx = tx
        self.witnesses = witnesses
    }
}

/// The result of `trp.submit`.
public struct SubmitResponse: Codable, Equatable, Sendable {
    /// The submitted transaction hash.
    public let hash: String

    /// Creates a submit response.
    public init(hash: String) {
        self.hash = hash
    }
}

/// A chain location at which a transaction was confirmed.
public struct ChainPoint: Codable, Equatable, Sendable {
    /// The chain slot.
    public let slot: Int64
    /// The block hash at the slot.
    public let blockHash: String

    /// Creates a chain point.
    public init(slot: Int64, blockHash: String) {
        self.slot = slot
        self.blockHash = blockHash
    }
}

/// A transaction's TRP lifecycle stage.
public enum TransactionStage: String, Codable, Sendable {
    case pending
    case propagated
    case acknowledged
    case confirmed
    case finalized
    case dropped
    case rolledBack = "rolled_back"
    case unknown
}

/// Status information for one transaction.
public struct TransactionStatus: Codable, Equatable, Sendable {
    /// The current lifecycle stage.
    public let stage: TransactionStage
    /// The number of confirmations.
    public let confirmations: Int64
    /// The number of non-confirmations.
    public let nonConfirmations: Int64
    /// The chain point at which the transaction was confirmed, when available.
    public let confirmedAt: ChainPoint?

    /// Creates transaction status information.
    public init(
        stage: TransactionStage,
        confirmations: Int64,
        nonConfirmations: Int64,
        confirmedAt: ChainPoint? = nil
    ) {
        self.stage = stage
        self.confirmations = confirmations
        self.nonConfirmations = nonConfirmations
        self.confirmedAt = confirmedAt
    }
}

/// Per-hash status information returned by `trp.checkStatus`.
public struct StatusResponse: Codable, Equatable, Sendable {
    /// Transaction statuses keyed by transaction hash.
    public let statuses: [String: TransactionStatus]

    /// Creates a status response.
    public init(statuses: [String: TransactionStatus]) {
        self.statuses = statuses
    }
}
