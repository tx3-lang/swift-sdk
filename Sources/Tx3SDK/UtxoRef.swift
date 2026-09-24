import Foundation

/// A reference to one transaction output.
public struct UtxoRef: Codable, Equatable, Hashable, Sendable {
    /// The transaction identifier bytes.
    public let txId: Data

    /// The zero-based output index.
    public let index: UInt32

    /// Creates a transaction-output reference.
    public init(txId: Data, index: UInt32) {
        self.txId = txId
        self.index = index
    }
}
