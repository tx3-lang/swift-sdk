import Foundation

/// An injectable HTTP boundary used by the low-level TRP client.
public protocol HTTPTransport: Sendable {
    /// Sends one request and returns its body and HTTP response.
    ///
    /// - Throws: A transport-specific error; the TRP client maps it to ``Tx3Error``.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production HTTP transport backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Creates a transport using the supplied URL session.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Sends one request through `URLSession`.
    ///
    /// Cancelling the calling task cancels the underlying URL session task.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}
