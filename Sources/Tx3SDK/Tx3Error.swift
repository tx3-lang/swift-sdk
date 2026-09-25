import Foundation

/// Failures while loading or validating a protocol interface.
public enum ProtocolFailure: Equatable, Sendable {
    /// A protocol file could not be read.
    case unreadable(path: String)
    /// A protocol document is not valid JSON.
    case invalidJSON(context: String)
    /// A protocol document does not satisfy the supported TII schema.
    case invalidSchema(context: String)
}

/// Failures while constructing an SDK client.
public enum ConstructionFailure: Equatable, Sendable {
    /// No TRP endpoint was configured.
    case missingTrpEndpoint
}

/// Failures while validating public contract values.
public enum ValidationFailure: Equatable, Sendable {
    /// A string is neither a checksummed Bech32 address nor hexadecimal bytes.
    case invalidAddress(String)
    /// An integer is outside the signed 128-bit Tx3 boundary.
    case integerOutOfRange
    /// A value does not match the expected public contract.
    case invalidValue(context: String)
}

/// Discriminated failures at the HTTP transport boundary.
public enum TransportFailure: Equatable, Sendable {
    /// The network request failed before an HTTP response arrived.
    case network(context: String)
    /// The endpoint returned a non-successful HTTP status.
    case httpStatus(code: Int, body: String?)
    /// The endpoint returned a JSON-RPC error.
    case jsonRPC(code: Int, message: String)
    /// The response could not be decoded as the expected contract.
    case malformedResponse(context: String)
    /// The request exceeded its configured timeout.
    case timeout
    /// The request was cancelled.
    case cancelled
}

/// Failures while validating or resolving transaction arguments.
public enum ResolutionFailure: Equatable, Sendable {
    /// A required transaction parameter was not provided.
    case missingParameter(name: String)
    /// A supplied argument did not match its declared type.
    case invalidArgument(path: String, expected: String)
    /// The resolver rejected the transaction request.
    case rejected(context: String)
}

/// Failures while producing transaction witnesses.
public enum SigningFailure: Equatable, Sendable {
    /// Key material does not satisfy the signer contract.
    case invalidKey
    /// A mnemonic does not satisfy BIP-39 validation.
    case invalidMnemonic
    /// A transaction hash is malformed or is not exactly 32 bytes.
    case invalidHash
    /// The supplied address is not a supported Cardano payment-key address.
    case invalidAddress
    /// A transaction hash is malformed or does not match the transaction.
    case hashMismatch
    /// The supplied address is not bound to the signing key.
    case addressMismatch
    /// The approved cryptographic primitive failed to produce a result.
    case cryptoFailure
    /// The signer rejected the request.
    case rejected(context: String)
}

/// Failures while submitting a signed transaction.
public enum SubmissionFailure: Equatable, Sendable {
    /// The submitted transaction hash differs from the expected hash.
    case hashMismatch
    /// The TRP endpoint rejected the signed transaction.
    case rejected(context: String)
}

/// Failures while waiting for a submitted transaction.
public enum PollingFailure: Equatable, Sendable {
    /// The chain reported a terminal failed stage.
    case terminal(stage: String)
    /// The transaction rolled back after appearing on-chain.
    case rolledBack
    /// Polling exhausted its configured attempts or deadline.
    case exhausted
    /// Polling was cancelled.
    case cancelled
}

/// The single public error boundary for Tx3 SDK operations.
public enum Tx3Error: Error, Equatable, Sendable {
    /// TII loading, parsing, or schema validation failed.
    case protocolError(ProtocolFailure)
    /// A transaction name is not declared by the protocol.
    case unknownTx(String)
    /// A profile name is not declared by the protocol.
    case unknownProfile(String)
    /// A party name is not declared by the protocol.
    case unknownParty(String)
    /// SDK client construction failed.
    case construction(ConstructionFailure)
    /// A public value failed validation.
    case validation(ValidationFailure)
    /// Communication with the TRP endpoint failed.
    case transport(TransportFailure)
    /// Transaction resolution failed.
    case resolution(ResolutionFailure)
    /// Transaction signing failed.
    case signing(SigningFailure)
    /// Transaction submission failed.
    case submission(SubmissionFailure)
    /// Transaction status polling failed.
    case polling(PollingFailure)
}
