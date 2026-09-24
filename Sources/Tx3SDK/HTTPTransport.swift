import Foundation

/// An injectable HTTP boundary used by the low-level TRP client.
public protocol HTTPTransport: Sendable {
    /// Sends one request and returns its body and HTTP response.
    ///
    /// - Throws: A transport-specific error; the TRP client maps it to ``Tx3Error``.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
