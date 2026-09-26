import CryptoKit
import Foundation

enum BIP39 {
    private static let englishWords: [String] = {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return contents.split(whereSeparator: \Character.isNewline).map(String.init)
    }()

    static func entropy(from phrase: String) throws -> Data {
        let normalized = phrase.decomposedStringWithCompatibilityMapping
        let words = normalized.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard [12, 15, 18, 21, 24].contains(words.count), englishWords.count == 2_048 else {
            throw Tx3Error.signing(.invalidMnemonic)
        }

        let lookup = Dictionary(uniqueKeysWithValues: englishWords.enumerated().map { ($1, $0) })
        guard words.allSatisfy({ lookup[$0] != nil }) else {
            throw Tx3Error.signing(.invalidMnemonic)
        }
        let indices = words.compactMap { lookup[$0] }
        let entropyBitCount = words.count * 11 * 32 / 33
        let checksumBitCount = words.count * 11 - entropyBitCount
        var entropy = Data(repeating: 0, count: entropyBitCount / 8)

        for bitIndex in 0..<entropyBitCount {
            let wordIndex = bitIndex / 11
            let bitInWord = 10 - (bitIndex % 11)
            let bit = (indices[wordIndex] >> bitInWord) & 1
            if bit == 1 {
                entropy[bitIndex / 8] |= UInt8(1 << (7 - bitIndex % 8))
            }
        }

        let digest = Data(SHA256.hash(data: entropy))
        for checksumIndex in 0..<checksumBitCount {
            let sourceIndex = entropyBitCount + checksumIndex
            let wordIndex = sourceIndex / 11
            let bitInWord = 10 - (sourceIndex % 11)
            let mnemonicBit = (indices[wordIndex] >> bitInWord) & 1
            let digestBit = Int((digest[checksumIndex / 8] >> (7 - checksumIndex % 8)) & 1)
            guard mnemonicBit == digestBit else {
                throw Tx3Error.signing(.invalidMnemonic)
            }
        }
        return entropy
    }
}
