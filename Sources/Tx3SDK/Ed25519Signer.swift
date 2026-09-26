import Foundation
import SwiftNaCl

/// A raw Ed25519 signer backed by a caller-supplied 32-byte private-key seed.
///
/// Signatures use deterministic RFC 8032 Ed25519. The signer retains only the key object required
/// for signing and never logs or includes key material in errors. Mnemonic derivation intentionally
/// belongs only to ``CardanoSigner``.
public struct Ed25519Signer: Signer {
    private let signingKey: SendableSigningKey
    private let signerAddress: Address

    /// Creates a raw Ed25519 signer.
    ///
    /// - Parameters:
    ///   - privateKey: Exactly 32 bytes of Ed25519 private-key seed material.
    ///   - address: The address exposed through ``Signer/address()``.
    /// - Throws: ``Tx3Error/signing(_:)`` with ``SigningFailure/invalidKey`` when the key does not
    ///   contain exactly 32 bytes or the approved Ed25519 primitive rejects it.
    public init(privateKey: Data, address: Address) throws {
        guard privateKey.count == 32 else {
            throw Tx3Error.signing(.invalidKey)
        }
        do {
            signingKey = try SendableSigningKey(seed: privateKey)
        } catch {
            throw Tx3Error.signing(.invalidKey)
        }
        signerAddress = address
    }

    /// Returns the address supplied when the signer was created.
    public func address() -> Address {
        signerAddress
    }

    /// Signs the decoded 32-byte transaction hash with Ed25519.
    ///
    /// - Throws: ``Tx3Error/signing(_:)`` with ``SigningFailure/invalidHash`` for malformed,
    ///   odd-length, or non-32-byte hash input, or ``SigningFailure/cryptoFailure`` when the
    ///   approved Ed25519 primitive cannot produce a signature.
    public func sign(_ request: SignRequest) throws -> Witness {
        let hash = try decodeSignerHex(request.txHashHex, expectedByteCount: 32)
        do {
            return Witness(
                publicKeyHex: signingKey.raw.verifyKey.bytes.lowercaseHex,
                signatureHex: try signingKey.raw.sign(message: hash).getSignature.lowercaseHex,
                type: .vkey
            )
        } catch {
            throw Tx3Error.signing(.cryptoFailure)
        }
    }
}

private final class SendableSigningKey: @unchecked Sendable {
    let raw: SigningKey

    init(seed: Data) throws {
        raw = try SigningKey(seed: seed)
    }
}
