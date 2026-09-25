import CryptoKit
import Foundation
import Testing

@testable import Tx3SDK

@Suite("Transaction signers")
struct SignerTests {
    @Test("raw Ed25519 signer matches the frozen independent vector")
    func rawEd25519Vector() throws {
        let vectors = try loadVectors()
        let raw = vectors.rawEd25519
        let address = try Address("00")
        let signer = try Ed25519Signer(
            privateKey: try decodeHex(raw.privateKeySeedHex),
            address: address
        )

        let witness = try signer.sign(
            SignRequest(txHashHex: raw.messageHex, txCborHex: "")
        )
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: try decodeHex(raw.expected.publicKeyHex)
        )
        let message = try decodeHex(raw.messageHex)

        #expect(signer.address() == address)
        #expect(witness.publicKeyHex == raw.expected.publicKeyHex)
        #expect(
            publicKey.isValidSignature(
                try decodeHex(raw.expected.signatureHex),
                for: message
            )
        )
        #expect(
            publicKey.isValidSignature(
                try decodeHex(witness.signatureHex),
                for: message
            )
        )
        #expect(witness.type == .vkey)
    }

    @Test("raw Ed25519 signer rejects invalid keys and hashes with typed errors")
    func rawEd25519Validation() throws {
        let address = try Address("00")
        #expect(throws: Tx3Error.signing(.invalidKey)) {
            try Ed25519Signer(privateKey: Data(repeating: 0, count: 31), address: address)
        }

        let signer = try Ed25519Signer(
            privateKey: Data(repeating: 0, count: 32),
            address: address
        )
        for malformedHash in ["0", "zz", String(repeating: "00", count: 31)] {
            #expect(throws: Tx3Error.signing(.invalidHash)) {
                try signer.sign(SignRequest(txHashHex: malformedHash, txCborHex: ""))
            }
        }
    }

    @Test("Cardano signer matches the frozen CIP-1852 key and address vector")
    func cardanoVector() throws {
        let vectors = try loadVectors()
        let cardano = vectors.cardanoCip1852
        let address = try Address(cardano.expected.address)
        let signer = try CardanoSigner(mnemonic: cardano.mnemonic, address: address)

        #expect(signer.address() == address)
        #expect(signer.derivedPublicKeyHex == cardano.expected.publicKeyHex)
        #expect(signer.derivedChainCodeHex == cardano.expected.chainCodeHex)

        let request = SignRequest(txHashHex: vectors.rawEd25519.messageHex, txCborHex: "")
        let witness = try signer.sign(request)
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: try decodeHex(witness.publicKeyHex)
        )
        #expect(
            publicKey.isValidSignature(
                try decodeHex(witness.signatureHex),
                for: try decodeHex(request.txHashHex)
            )
        )
        #expect(witness.publicKeyHex == cardano.expected.publicKeyHex)
        #expect(witness.type == .vkey)

        let paymentCredential = try decodeHex(
            "0fdc780023d8be7c9ff3a6bdc0d8d3b263bd0cc12448c40948efbf42"
        )
        let baseAddressText = bech32Address(
            bytes: [0x00] + Array(paymentCredential) + Array(repeating: 0, count: 28),
            prefix: "addr_test"
        )
        #expect(baseAddressText.count > 90)
        let baseAddress = try Address(baseAddressText)
        #expect(
            try CardanoSigner(mnemonic: cardano.mnemonic, address: baseAddress).address()
                == baseAddress)
    }

    @Test("Cardano signer validates mnemonic and payment credential")
    func cardanoValidation() throws {
        let vectors = try loadVectors()
        let cardano = vectors.cardanoCip1852
        let expectedAddress = try Address(cardano.expected.address)

        #expect(throws: Tx3Error.signing(.invalidMnemonic)) {
            try CardanoSigner(
                mnemonic: cardano.mnemonic.replacingOccurrences(of: "about", with: "abandon"),
                address: expectedAddress
            )
        }

        let differentPaymentAddress = try Address(
            bech32Address(bytes: [0x60] + Array(repeating: 0, count: 28), prefix: "addr_test")
        )
        #expect(throws: Tx3Error.signing(.addressMismatch)) {
            try CardanoSigner(mnemonic: cardano.mnemonic, address: differentPaymentAddress)
        }
        #expect(throws: Tx3Error.signing(.invalidAddress)) {
            try CardanoSigner(mnemonic: cardano.mnemonic, address: try Address("00"))
        }
    }

    @Test("consumers can provide their own signer implementation")
    func customSigner() throws {
        struct ConsumerSigner: Signer {
            let boundAddress: Address

            func address() -> Address { boundAddress }

            func sign(_ request: SignRequest) throws -> Witness {
                Witness(
                    publicKeyHex: request.txHashHex, signatureHex: request.txCborHex, type: .vkey)
            }
        }

        let signer: any Signer = ConsumerSigner(boundAddress: try Address("00"))
        let witness = try signer.sign(SignRequest(txHashHex: "aa", txCborHex: "bb"))
        #expect(witness == Witness(publicKeyHex: "aa", signatureHex: "bb", type: .vkey))
    }
}

private struct SignerVectors: Decodable {
    struct CardanoExpected: Decodable {
        let publicKeyHex: String
        let chainCodeHex: String
        let address: String
    }

    struct RawExpected: Decodable {
        let publicKeyHex: String
        let signatureHex: String
    }

    struct Cardano: Decodable {
        let mnemonic: String
        let expected: CardanoExpected
    }

    struct RawEd25519: Decodable {
        let privateKeySeedHex: String
        let messageHex: String
        let expected: RawExpected
    }

    let cardanoCip1852: Cardano
    let rawEd25519: RawEd25519
}

private func loadVectors() throws -> SignerVectors {
    let url = try #require(
        Bundle.module.url(forResource: "signer-vectors", withExtension: "json")
    )
    return try JSONDecoder().decode(SignerVectors.self, from: Data(contentsOf: url))
}

private func decodeHex(_ value: String) throws -> Data {
    guard value.count.isMultiple(of: 2) else { throw FixtureError.invalidHex }
    var bytes = Data()
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else {
            throw FixtureError.invalidHex
        }
        bytes.append(byte)
        index = next
    }
    return bytes
}

private func bech32Address(bytes: [UInt8], prefix: String) -> String {
    let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    let words = convertBits(bytes, from: 8, to: 5, pad: true)
    let expandedPrefix =
        prefix.unicodeScalars.map { Int($0.value >> 5) }
        + [0]
        + prefix.unicodeScalars.map { Int($0.value & 31) }
    let checksumInput = expandedPrefix + words + Array(repeating: 0, count: 6)
    let checksum = bech32Polymod(checksumInput) ^ 1
    let checksumWords = (0..<6).map { (checksum >> (5 * (5 - $0))) & 31 }
    return prefix + "1" + String((words + checksumWords).map { alphabet[$0] })
}

private func convertBits(_ bytes: [UInt8], from: Int, to: Int, pad: Bool) -> [Int] {
    var accumulator = 0
    var bitCount = 0
    let outputMask = (1 << to) - 1
    let accumulatorMask = (1 << (from + to - 1)) - 1
    var output: [Int] = []
    for byte in bytes {
        accumulator = ((accumulator << from) | Int(byte)) & accumulatorMask
        bitCount += from
        while bitCount >= to {
            bitCount -= to
            output.append((accumulator >> bitCount) & outputMask)
        }
    }
    if pad, bitCount > 0 {
        output.append((accumulator << (to - bitCount)) & outputMask)
    }
    return output
}

private func bech32Polymod(_ values: [Int]) -> Int {
    let generators = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
    return values.reduce(1) { checksum, value in
        let top = checksum >> 25
        var next = ((checksum & 0x1ff_ffff) << 5) ^ value
        for index in generators.indices where ((top >> index) & 1) == 1 {
            next ^= generators[index]
        }
        return next
    }
}

private enum FixtureError: Error {
    case invalidHex
}
