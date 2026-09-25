import CryptoKit
import Foundation
import SwiftNaCl

/// A Cardano signer derived from a BIP-39 mnemonic at `m/1852'/1815'/0'/0/0`.
///
/// Construction validates the mnemonic checksum and proves that the derived payment key matches
/// the supplied address. The mnemonic and its entropy are not retained or included in diagnostics;
/// only the derived signing key and chain code required by the signer are stored.
public struct CardanoSigner: Signer {
    private let signerAddress: Address
    private let extendedSecret: Data
    private let publicKey: Data
    private let chainCode: Data

    /// Creates a Cardano signer from a BIP-39 English mnemonic and matching address.
    ///
    /// - Parameters:
    ///   - mnemonic: A checksum-valid 12-, 15-, 18-, 21-, or 24-word BIP-39 English phrase.
    ///   - address: A Shelley base or enterprise address whose payment credential is this key.
    /// - Throws: ``Tx3Error/signing(_:)`` with ``SigningFailure/invalidMnemonic``,
    ///   ``SigningFailure/invalidAddress``, ``SigningFailure/addressMismatch``, or
    ///   ``SigningFailure/cryptoFailure`` as appropriate.
    public init(mnemonic: String, address: Address) throws {
        do {
            let entropy = try BIP39.entropy(from: mnemonic)
            let paymentKey = try CardanoKeyDerivation.paymentKey(from: entropy)
            let publicKey = try CardanoKeyDerivation.publicKey(for: paymentKey.secret)
            let paymentCredential = try CardanoAddress.paymentCredential(from: address.value)
            let publicKeyHash = try Sodium().cryptoGenericHash.blake2bSaltPersonal(
                data: publicKey,
                digestSize: 28
            )
            guard Sodium().utils.sodiumMemcmp(paymentCredential, publicKeyHash) else {
                throw Tx3Error.signing(.addressMismatch)
            }

            signerAddress = address
            extendedSecret = paymentKey.secret
            self.publicKey = publicKey
            chainCode = paymentKey.chainCode
        } catch let error as Tx3Error {
            throw error
        } catch {
            throw Tx3Error.signing(.cryptoFailure)
        }
    }

    /// Returns the address whose payment credential was verified during construction.
    public func address() -> Address {
        signerAddress
    }

    /// Signs the decoded 32-byte transaction hash with the derived extended Ed25519 key.
    ///
    /// - Throws: ``Tx3Error/signing(_:)`` with ``SigningFailure/invalidHash`` for malformed,
    ///   odd-length, or non-32-byte hash input, or ``SigningFailure/cryptoFailure`` when the
    ///   approved cryptographic primitive cannot produce a signature.
    public func sign(_ request: SignRequest) throws -> Witness {
        let hash = try decodeSignerHex(request.txHashHex, expectedByteCount: 32)
        do {
            return Witness(
                publicKeyHex: publicKey.lowercaseHex,
                signatureHex: try CardanoKeyDerivation.sign(
                    hash,
                    extendedSecret: extendedSecret,
                    publicKey: publicKey
                ).lowercaseHex,
                type: .vkey
            )
        } catch {
            throw Tx3Error.signing(.cryptoFailure)
        }
    }

    var derivedPublicKeyHex: String {
        publicKey.lowercaseHex
    }

    var derivedChainCodeHex: String {
        chainCode.lowercaseHex
    }
}

private struct ExtendedPrivateKey {
    let secret: Data
    let chainCode: Data
}

private enum CardanoKeyDerivation {
    private static var sodium: Sodium { Sodium() }

    static func paymentKey(from entropy: Data) throws -> ExtendedPrivateKey {
        var root = pbkdf2SHA512(
            password: Data(),
            salt: entropy,
            iterations: 4_096,
            outputByteCount: 96
        )
        root[0] &= 0xf8
        root[31] &= 0x1f
        root[31] |= 0x40

        var key = ExtendedPrivateKey(
            secret: Data(root.prefix(64)),
            chainCode: Data(root.suffix(32))
        )
        for index in [
            UInt32(1_852) | 0x8000_0000,
            UInt32(1_815) | 0x8000_0000,
            UInt32(0) | 0x8000_0000,
            UInt32(0),
            UInt32(0),
        ] {
            key = try deriveChild(of: key, index: index)
        }
        return key
    }

    static func publicKey(for extendedSecret: Data) throws -> Data {
        let scalar = try reducedScalar(Data(extendedSecret.prefix(32)))
        return try sodium.cryptoScalarmult.ed25519BaseNoclamp(n: scalar)
    }

    static func sign(_ message: Data, extendedSecret: Data, publicKey: Data) throws -> Data {
        let prefix = Data(extendedSecret.suffix(32))
        let nonce = try sodium.cryptoCore.ed25519ScalarReduce(
            sodium.cryptoHash.sha512(message: prefix + message)
        )
        let encodedPoint = try sodium.cryptoScalarmult.ed25519BaseNoclamp(n: nonce)
        let challenge = try sodium.cryptoCore.ed25519ScalarReduce(
            sodium.cryptoHash.sha512(message: encodedPoint + publicKey + message)
        )
        let signingScalar = try reducedScalar(Data(extendedSecret.prefix(32)))
        let product = try sodium.cryptoCore.ed25519ScalarMul(challenge, signingScalar)
        let response = try sodium.cryptoCore.ed25519ScalarAdd(product, nonce)
        return encodedPoint + response
    }

    private static func deriveChild(of parent: ExtendedPrivateKey, index: UInt32) throws
        -> ExtendedPrivateKey
    {
        let hardened = index >= 0x8000_0000
        let keyMaterial = hardened ? parent.secret : try publicKey(for: parent.secret)
        var data = Data([hardened ? 0x00 : 0x02])
        data.append(keyMaterial)
        data.append(contentsOf: littleEndianBytes(index))

        let z = hmacSHA512(key: parent.chainCode, data: data)
        data[0] = hardened ? 0x01 : 0x03
        let chainDigest = hmacSHA512(key: parent.chainCode, data: data)

        var child = Data(repeating: 0, count: 64)
        var carry = UInt32(0)
        for byteIndex in 0..<28 {
            let sum = UInt32(parent.secret[byteIndex]) + UInt32(z[byteIndex]) * 8 + carry
            child[byteIndex] = UInt8(sum & 0xff)
            carry = sum >> 8
        }
        for byteIndex in 28..<32 {
            let sum = UInt32(parent.secret[byteIndex]) + carry
            child[byteIndex] = UInt8(sum & 0xff)
            carry = sum >> 8
        }

        carry = 0
        for byteIndex in 0..<32 {
            let sum =
                UInt32(parent.secret[32 + byteIndex]) + UInt32(z[32 + byteIndex]) + carry
            child[32 + byteIndex] = UInt8(sum & 0xff)
            carry = sum >> 8
        }

        return ExtendedPrivateKey(secret: child, chainCode: Data(chainDigest.suffix(32)))
    }

    private static func reducedScalar(_ value: Data) throws -> Data {
        var wide = value
        wide.append(Data(repeating: 0, count: 32))
        return try sodium.cryptoCore.ed25519ScalarReduce(wide)
    }

    private static func pbkdf2SHA512(
        password: Data,
        salt: Data,
        iterations: Int,
        outputByteCount: Int
    ) -> Data {
        let key = SymmetricKey(data: password)
        let blockCount = (outputByteCount + 63) / 64
        var result = Data()
        result.reserveCapacity(blockCount * 64)

        for blockIndex in 1...blockCount {
            var input = salt
            input.append(contentsOf: bigEndianBytes(UInt32(blockIndex)))
            var current = Data(HMAC<SHA512>.authenticationCode(for: input, using: key))
            var accumulated = current
            for _ in 1..<iterations {
                current = Data(HMAC<SHA512>.authenticationCode(for: current, using: key))
                for byteIndex in accumulated.indices {
                    accumulated[byteIndex] ^= current[byteIndex]
                }
            }
            result.append(accumulated)
        }
        return Data(result.prefix(outputByteCount))
    }

    private static func hmacSHA512(key: Data, data: Data) -> Data {
        Data(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff),
        ]
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
    }
}

private enum CardanoAddress {
    static func paymentCredential(from value: String) throws -> Data {
        guard let decoded = decodeBech32(value), decoded.bytes.count >= 29 else {
            throw Tx3Error.signing(.invalidAddress)
        }

        let header = decoded.bytes[0]
        let addressType = header >> 4
        let network = header & 0x0f
        let expectedPrefix = network == 1 ? "addr" : "addr_test"
        guard decoded.prefix == expectedPrefix else {
            throw Tx3Error.signing(.invalidAddress)
        }

        switch addressType {
        case 0, 2:
            guard decoded.bytes.count == 57 else {
                throw Tx3Error.signing(.invalidAddress)
            }
        case 6:
            guard decoded.bytes.count == 29 else {
                throw Tx3Error.signing(.invalidAddress)
            }
        default:
            throw Tx3Error.signing(.invalidAddress)
        }
        return Data(decoded.bytes[1..<29])
    }

    private static func decodeBech32(_ value: String) -> (prefix: String, bytes: [UInt8])? {
        guard value == value.lowercased() || value == value.uppercased() else {
            return nil
        }
        let normalized = value.lowercased()
        guard let separator = normalized.lastIndex(of: "1") else {
            return nil
        }
        let prefix = String(normalized[..<separator])
        let payload = normalized[normalized.index(after: separator)...]
        guard !prefix.isEmpty, payload.count >= 6, normalized.count <= 1023 else {
            return nil
        }

        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
        guard let values = payload.map({ lookup[$0] }) as? [Int], polymod(prefix, values) == 1
        else {
            return nil
        }
        let dataWords = values.dropLast(6)
        guard let bytes = convertBits(Array(dataWords), from: 5, to: 8) else {
            return nil
        }
        return (prefix, bytes)
    }

    private static func polymod(_ prefix: String, _ values: [Int]) -> Int {
        var expanded = prefix.unicodeScalars.map { Int($0.value >> 5) }
        expanded.append(0)
        expanded.append(contentsOf: prefix.unicodeScalars.map { Int($0.value & 31) })
        let generators = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        return (expanded + values).reduce(1) { checksum, value in
            let top = checksum >> 25
            var next = ((checksum & 0x1ff_ffff) << 5) ^ value
            for index in generators.indices where ((top >> index) & 1) == 1 {
                next ^= generators[index]
            }
            return next
        }
    }

    private static func convertBits(_ values: [Int], from: Int, to: Int) -> [UInt8]? {
        var accumulator = 0
        var bitCount = 0
        let outputMask = (1 << to) - 1
        let accumulatorMask = (1 << (from + to - 1)) - 1
        var output: [UInt8] = []

        for value in values {
            guard value >= 0, value >> from == 0 else { return nil }
            accumulator = ((accumulator << from) | value) & accumulatorMask
            bitCount += from
            while bitCount >= to {
                bitCount -= to
                output.append(UInt8((accumulator >> bitCount) & outputMask))
            }
        }
        guard bitCount < from, ((accumulator << (to - bitCount)) & outputMask) == 0 else {
            return nil
        }
        return output
    }
}
