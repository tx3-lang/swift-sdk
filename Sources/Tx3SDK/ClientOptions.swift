import Foundation

/// Immutable configuration for a TRP client.
public struct ClientOptions: Sendable {
    /// The TRP JSON-RPC endpoint.
    public let endpoint: URL

    /// Additional HTTP headers sent with each request.
    public let headers: [String: String]

    /// An optional per-request timeout.
    public let timeout: Duration?

    /// Creates TRP client configuration.
    public init(
        endpoint: URL,
        headers: [String: String] = [:],
        timeout: Duration? = nil
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.timeout = timeout
    }
}
