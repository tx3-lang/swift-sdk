import Foundation

/// The payload supplied to a transaction signer.
public struct SignRequest: Codable, Equatable, Sendable {
    /// Hexadecimal bytes of the bound transaction hash.
    public let txHashHex: String

    /// Hexadecimal CBOR bytes of the complete transaction.
    public let txCborHex: String

    /// Creates a signing request containing both hash- and transaction-oriented payloads.
    public init(txHashHex: String, txCborHex: String) {
        self.txHashHex = txHashHex
        self.txCborHex = txCborHex
    }
}

/// The supported witness envelope type.
public enum WitnessType: String, Codable, Sendable {
    /// A verification-key witness.
    case vkey
}

/// A transaction witness returned by a signer.
public struct Witness: Codable, Equatable, Sendable {
    /// The hexadecimal public-key envelope.
    public let publicKeyHex: String

    /// The hexadecimal signature envelope.
    public let signatureHex: String

    /// The witness envelope type.
    public let type: WitnessType

    /// Creates a witness value.
    public init(publicKeyHex: String, signatureHex: String, type: WitnessType) {
        self.publicKeyHex = publicKeyHex
        self.signatureHex = signatureHex
        self.type = type
    }
}

/// A synchronous, user-extensible transaction signer.
public protocol Signer: Sendable {
    /// Returns the address bound to this signer.
    func address() -> Address

    /// Signs a transaction request.
    ///
    /// - Throws: ``Tx3Error/signing(_:)`` when signing cannot produce a valid witness.
    func sign(_ request: SignRequest) throws -> Witness
}
