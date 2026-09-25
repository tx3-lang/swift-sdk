import Foundation

/// A low-level client for the Transaction Resolver Protocol JSON-RPC API.
public actor TRPClient {
    private struct JSONRPCRequest<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: Params
        let id: String
    }

    private struct JSONRPCResponse<Result: Decodable>: Decodable {
        let jsonrpc: String?
        let result: Result?
        let error: JSONRPCError?
        let id: String?
    }

    private struct JSONRPCError: Decodable {
        let code: Int
        let message: String
    }

    private struct StatusParams: Encodable {
        let hashes: [String]
    }

    private struct TimedOut: Error {}

    private let options: ClientOptions
    private let transport: any HTTPTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var nextRequestID: UInt64 = 1

    /// Creates a client using the production URL session transport.
    public init(options: ClientOptions) {
        self.init(options: options, transport: URLSessionTransport())
    }

    /// Creates a client with an injectable transport.
    ///
    /// - Parameters:
    ///   - options: Endpoint, headers, and timeout configuration.
    ///   - transport: The HTTP boundary used for every request.
    public init(options: ClientOptions, transport: any HTTPTransport) {
        self.options = options
        self.transport = transport
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    /// Resolves a TIR transaction into transaction bytes and a transaction hash.
    ///
    /// - Throws: ``Tx3Error/transport(_:)`` for transport, server, or response failures.
    public func resolve(_ params: ResolveParams) async throws -> ResolveResponse {
        try await call(method: "trp.resolve", params: params)
    }

    /// Submits a resolved transaction and its witnesses.
    ///
    /// - Throws: ``Tx3Error/transport(_:)`` for transport, server, or response failures.
    public func submit(_ params: SubmitParams) async throws -> SubmitResponse {
        try await call(method: "trp.submit", params: params)
    }

    /// Returns status information for the requested transaction hashes.
    ///
    /// Unknown stage values are rejected as malformed responses.
    ///
    /// - Throws: ``Tx3Error/transport(_:)`` for transport, server, or response failures.
    public func checkStatus(_ hashes: [String]) async throws -> StatusResponse {
        try await call(method: "trp.checkStatus", params: StatusParams(hashes: hashes))
    }

    private func call<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params
    ) async throws -> Result {
        let id = String(nextRequestID)
        nextRequestID += 1

        var request = URLRequest(url: options.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in options.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            request.httpBody = try encoder.encode(
                JSONRPCRequest(method: method, params: params, id: id)
            )
        } catch {
            throw Tx3Error.transport(
                .malformedResponse(context: "Could not encode \(method) parameters")
            )
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch is TimedOut {
            throw Tx3Error.transport(.timeout)
        } catch is CancellationError {
            throw Tx3Error.transport(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            throw Tx3Error.transport(.cancelled)
        } catch let error as URLError where error.code == .timedOut {
            throw Tx3Error.transport(.timeout)
        } catch let error as Tx3Error {
            throw error
        } catch {
            throw Tx3Error.transport(.network(context: String(describing: error)))
        }

        guard (200...299).contains(response.statusCode) else {
            throw Tx3Error.transport(
                .httpStatus(code: response.statusCode, body: Self.diagnosticBody(data))
            )
        }

        let rpc: JSONRPCResponse<Result>
        do {
            rpc = try decoder.decode(JSONRPCResponse<Result>.self, from: data)
        } catch {
            throw Tx3Error.transport(
                .malformedResponse(context: "Invalid JSON-RPC response for \(method)")
            )
        }

        guard rpc.jsonrpc == "2.0", rpc.id == id else {
            throw Tx3Error.transport(
                .malformedResponse(context: "Mismatched JSON-RPC version or request ID")
            )
        }
        if let error = rpc.error {
            guard rpc.result == nil else {
                throw Tx3Error.transport(
                    .malformedResponse(context: "JSON-RPC response contains result and error")
                )
            }
            throw Tx3Error.transport(.jsonRPC(code: error.code, message: error.message))
        }
        guard let result = rpc.result else {
            throw Tx3Error.transport(
                .malformedResponse(context: "JSON-RPC response is missing a result")
            )
        }
        return result
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let timeout = options.timeout else {
            return try await transport.send(request)
        }
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await self.transport.send(request) }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private static func diagnosticBody(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let limit = 1_024
        let prefix = data.prefix(limit)
        let body = String(decoding: prefix, as: UTF8.self)
        return data.count > limit ? body + "…" : body
    }
}
