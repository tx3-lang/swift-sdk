import Foundation

struct TransactionSigner: Sendable {
    let name: String
    let address: Address
    let signer: any Signer
}

/// Configuration for transaction-status polling.
public struct PollConfig: Equatable, Sendable {
    /// The maximum number of status requests.
    public let attempts: Int

    /// The delay between status requests.
    public let delay: Duration

    /// Creates polling configuration, defaulting to 20 attempts five seconds apart.
    ///
    /// - Throws: ``Tx3Error/validation(_:)`` when `attempts` is not positive or `delay` is
    ///   negative.
    public init(attempts: Int = 20, delay: Duration = .seconds(5)) throws {
        guard attempts > 0 else {
            throw Tx3Error.validation(
                .invalidValue(context: "PollConfig attempts must be positive")
            )
        }
        guard delay >= .zero else {
            throw Tx3Error.validation(
                .invalidValue(context: "PollConfig delay must not be negative")
            )
        }
        self.attempts = attempts
        self.delay = delay
    }
}

protocol PollClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousPollClock: PollClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

/// The status returned by transaction wait methods.
public typealias TxStatus = TransactionStatus

extension ResolvedTx {
    /// The transaction hash supplied to every registered signer.
    public var signingHash: String { hash }

    /// Returns a copy with an externally produced TRP witness attached.
    ///
    /// Manual witnesses are not verified locally. They are submitted after automatic signer
    /// witnesses, in attachment order.
    public func addWitness(_ witness: TxWitness) -> ResolvedTx {
        ResolvedTx(
            trp: trp,
            hash: hash,
            txHex: txHex,
            signers: signers,
            manualWitnesses: manualWitnesses + [witness]
        )
    }

    /// Returns a copy with a public signer witness attached for external-wallet submission.
    public func addWitness(_ witness: Witness) -> ResolvedTx {
        addWitness(Self.trpWitness(from: witness))
    }

    /// Produces automatic witnesses in party-binding order, then appends manual witnesses.
    ///
    /// Both the resolved transaction hash and full CBOR are supplied to every signer.
    /// External-witness-only signing is supported.
    ///
    /// - Throws: ``Tx3Error/signing(_:)`` when a signer rejects the request.
    public func sign() throws -> SignedTx {
        guard let trp else {
            throw Tx3Error.signing(
                .rejected(context: "Resolved transaction is not bound to a TRP client")
            )
        }

        let request = SignRequest(txHashHex: hash, txCborHex: txHex)
        var witnesses: [TxWitness] = []
        witnesses.reserveCapacity(signers.count + manualWitnesses.count)
        for entry in signers {
            do {
                witnesses.append(Self.trpWitness(from: try entry.signer.sign(request)))
            } catch let error as Tx3Error {
                throw error
            } catch {
                throw Tx3Error.signing(.rejected(context: String(describing: error)))
            }
        }
        witnesses.append(contentsOf: manualWitnesses)

        return SignedTx(
            trp: trp,
            hash: hash,
            submitParams: SubmitParams(
                tx: BytesEnvelope(content: txHex, contentType: "hex"),
                witnesses: witnesses
            )
        )
    }

    private static func trpWitness(from witness: Witness) -> TxWitness {
        .signature(
            TxSignature(
                key: BytesEnvelope(content: witness.publicKeyHex, contentType: "hex"),
                signature: BytesEnvelope(content: witness.signatureHex, contentType: "hex"),
                type: witness.type.rawValue
            )
        )
    }
}

/// A signed transaction ready for submission.
public struct SignedTx: Sendable {
    /// The locally resolved transaction hash.
    public let hash: String

    /// The exact transaction and ordered witnesses sent to TRP.
    public let submitParams: SubmitParams

    let trp: TRPClient

    init(trp: TRPClient, hash: String, submitParams: SubmitParams) {
        self.trp = trp
        self.hash = hash
        self.submitParams = submitParams
    }

    /// Submits the signed transaction and verifies the server-returned hash.
    ///
    /// - Throws: ``Tx3Error/submission(_:)`` when the returned hash differs from the local hash,
    ///   or a typed transport failure from the TRP client.
    public func submit() async throws -> SubmittedTx {
        let response = try await trp.submit(submitParams)
        guard response.hash == hash else {
            throw Tx3Error.submission(.hashMismatch)
        }
        return SubmittedTx(trp: trp, hash: response.hash)
    }
}

/// A submitted transaction that can be awaited through confirmed or finalized status.
public struct SubmittedTx: Sendable {
    /// The server-confirmed submitted transaction hash.
    public let hash: String

    let trp: TRPClient
    private let clock: any PollClock

    init(trp: TRPClient, hash: String, clock: any PollClock = ContinuousPollClock()) {
        self.trp = trp
        self.hash = hash
        self.clock = clock
    }

    /// Waits until the transaction is confirmed or finalized.
    ///
    /// - Throws: ``Tx3Error/polling(_:)`` for dropped, rolled-back, exhausted, or cancelled
    ///   polling, or a typed transport failure from the TRP client.
    public func waitForConfirmed(_ config: PollConfig) async throws -> TxStatus {
        try await wait(config, target: .confirmed)
    }

    /// Waits until the transaction is finalized.
    ///
    /// - Throws: ``Tx3Error/polling(_:)`` for dropped, rolled-back, exhausted, or cancelled
    ///   polling, or a typed transport failure from the TRP client.
    public func waitForFinalized(_ config: PollConfig) async throws -> TxStatus {
        try await wait(config, target: .finalized)
    }

    private func wait(_ config: PollConfig, target: TransactionStage) async throws -> TxStatus {
        for attempt in 1...config.attempts {
            do {
                try Task.checkCancellation()
                let response = try await trp.checkStatus([hash])
                if let status = response.statuses[hash] {
                    switch status.stage {
                    case .finalized:
                        return status
                    case .confirmed where target == .confirmed:
                        return status
                    case .dropped:
                        throw Tx3Error.polling(.terminal(stage: status.stage.rawValue))
                    case .rolledBack:
                        throw Tx3Error.polling(.rolledBack)
                    default:
                        break
                    }
                }
                if attempt < config.attempts {
                    try await clock.sleep(for: config.delay)
                }
            } catch is CancellationError {
                throw Tx3Error.polling(.cancelled)
            } catch Tx3Error.transport(.cancelled) where Task.isCancelled {
                throw Tx3Error.polling(.cancelled)
            }
        }
        throw Tx3Error.polling(.exhausted)
    }
}
